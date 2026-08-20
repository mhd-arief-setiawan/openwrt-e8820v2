# ZTE E8820V2 — Agent Handoff Notes

Runbook for reconfiguring this router. Read this **before** touching it — several
non-obvious constraints will bite you otherwise. Last verified: 2026-08-20.

---

## 1. What this device is

- **ZTE E8820V2**: MT7621A SoC, **16 MB SPI-NOR flash, 64 MB RAM**, 5× gigabit
  ports (MT7621 DSA switch), MT7603E (2.4 GHz) + **MT7612E (5 GHz)** radios.
- Running a **custom OpenWrt 23.05.6, 5 GHz-only** build (kmod-mt7603 omitted).
  Source/build: GitHub `mhd-arief-setiawan/openwrt-e8820v2`, local mirror
  `d:\Projects\openwrt-router\build-repo`.
- **Breed bootloader is present** → a bad flash is recoverable (hold reset at
  power-on, browse to 192.168.1.1). Full original **Padavan** firmware + factory
  (WiFi calibration) + bootloader backups are in `d:\Projects\openwrt-router\backups\`.

## 2. Access

| | |
|---|---|
| LuCI / SSH | `root` / `@Hammadar4549` |
| Management IP | **10.0.10.1** (Trusted VLAN) |
| **Reliable mgmt channel** | **IPv6 link-local `fe80::7e39:55ff:fe61:1a8e%<ifindex>`** |

The router LAN MAC is `7c:39:55:61:1a:8e`, so its IPv6 link-local is always
`fe80::7e39:55ff:fe61:1a8e`. This works **regardless of IPv4/VLAN state** and is
the ONLY thing that stayed reliable through every reconfig — prefer it.
On the Windows PC, find `<ifindex>` with `Get-NetAdapter -Name Ethernet` (was `15`).
SSH auth: password `@Hammadar4549` normally; **none-auth (no password)** right
after a factory-fresh flash.

## 3. ⚠️ Critical constraints (these caused days of pain — do not relearn them)

1. **5 GHz MUST be VHT40, never VHT80/HE80/80 MHz.** At 80 MHz the mt76 driver's
   DMA buffers exceed what 64 MB can give → endless `ieee80211 phyN: Hardware
   restart was requested` loop (~1/sec, radio unusable). **VHT40 is stable**
   (~200–300 Mbps). This is the single most important rule.
2. **RAM is at the ceiling.** ~0.5–2 MB free with 5 VLANs + 2 APs (zram-swap
   cushions it). **Two SSIDs is the practical max.** Do NOT `opkg install` heavy
   packages — even `opkg update` can OOM. For QoS use built-in **nftables/fw4**,
   never SQM/tc.
3. **`setsid` does NOT exist** on this build. To detach a background job (e.g. a
   config-apply that restarts the network and will drop your SSH), use:
   `start-stop-daemon -S -b -x /bin/sh -- /tmp/script.sh`
   (A plain `cmd &` over SSH gets killed when the session closes.)
4. **Flash with mtd streaming, not sysupgrade/LuCI** (they stage the image in
   tmpfs and OOM): `cat img.bin | ssh root@ROUTER 'mtd -r write - firmware'`.
   To go factory-fresh, `mtd erase rootfs_data` first (or it's implicit on a
   squashfs firmware write + reboot).
5. **Cloudflare WARP on the PC** intermittently RESETs LAN connections and blocks
   DHCP **even when the client shows "Disconnected"** — its filter driver stays
   active. For reliable router access, fully **stop the CloudflareWARP service**
   (needs admin: `Stop-Service CloudflareWARP -Force`). Symptom: TCP connects then
   handshake resets (WinError 10053/10054), or PC stuck on 169.254.x.
6. **L2 is hardware-offloaded** (MT7621 switch) → `bridge fdb show` is empty. To
   find which physical port a device is on, compare `/sys/class/net/lanN/
   statistics/rx_packets` before/after a traffic burst, not the fdb.
7. **PCIe radio cold-boot is flaky.** The MT7612 (and MT7603) sometimes fail their
   PCIe ROM handshake on cold boot; `/etc/rc.local` re-binds the MT7621 PCIe
   controller when the PHY is missing and reconciles the radio→PHY mapping **by
   driver** (the PCI path shifts between boots — never hardcode it).

## 4. Current configuration

**Subnets** (3rd octet = VLAN ID):

| Zone | VLAN | Subnet / GW | Notes |
|---|---|---|---|
| Management | 1 | 10.0.1.1/24 | admin |
| Trusted | 10 | 10.0.10.1/24 | PC, main 5G SSID |
| IoT | 20 | 10.0.20.1/24 | (no SSID yet) |
| Guest | 30 | 10.0.30.1/24 | open SSID, 5 Mbps cap |
| Servers | 40 | 10.0.40.1/24 | Proxmox 10.0.40.2 |

**Ports** (DSA bridge-vlan on `br-lan`, sections `network.v1/v10/v20/v30/v40`):

| Port | Mode | VLANs |
|---|---|---|
| WAN | uplink (DHCP; behind ISP modem 192.168.100.1, router got .100.3) | — |
| LAN1, LAN2 | trunk | 1,10,20,30,40 tagged |
| LAN3 | access | untagged 40 (Servers) — **Proxmox** |
| LAN4 | access | untagged 10 (Trusted) — **PC** (`a8:a1:59:e7:b8:a4`) |

**Firewall** (fw4/nftables): zones `trusted`,`mgmt` (input ACCEPT), `iot`,`guest`,
`servers` (input REJECT + allow DHCP/DNS to router). Forwardings: `trusted`→
wan,iot,servers,mgmt; `mgmt`→wan,trusted,iot,servers; `guest`→wan; `servers`→wan;
`iot`→wan. (Guest/IoT internet-only, isolated from other internal zones.)

**Wireless** (`radio0` = the only radio = mt76x2e 5 GHz; `radio0.path` is rewritten
each boot by rc.local — don't rely on its stored value):
- `wlan_trusted`: SSID **Alfarel-Home**, network `trusted`, WPA2 (`@Hammadar4549`).
- `wlan_guest`: SSID **Alfarel-Home-Guest**, network `guest`, **encryption none**
  (open), `isolate=1`.
- Both on channel 36, **htmode VHT40**, country ID.

**Guest 5 Mbps cap**: `/etc/nftables.d/20-guest-qos.nft` (repo: `files/guest-qos.nft`)
— an fw4 include adding chain `guest_qos` with an nftables policer on `br-lan.30`
(both directions, ~610 kbytes/s ≈ 5 Mbps, TOTAL for the guest network). Persists
via fw4 auto-loading `/etc/nftables.d/`.

**IPv6 is disabled** (`network.wan6` removed, `odhcpd` disabled) to save RAM.

## 5. Reconfiguration recipes

Connect first (from the PC, adjust ifindex): use the repo's helper pattern or any
SSH client to `root@10.0.10.1` (pw `@Hammadar4549`) or
`root@fe80::7e39:55ff:fe61:1a8e%<ifindex>`.

- **Change a WiFi password:** `uci set wireless.wlan_trusted.key='NEWPASS';
  uci commit wireless; wifi reload`.
- **Add the IoT SSID** (⚠️ 3rd BSS — likely OOMs on 64 MB; test memory, be ready
  to revert): `uci set wireless.wlan_iot=wifi-iface; uci set wireless.wlan_iot.device=radio0;
  uci set wireless.wlan_iot.mode=ap; uci set wireless.wlan_iot.network=iot;
  uci set wireless.wlan_iot.ssid=Alfarel-Home-IoT; uci set wireless.wlan_iot.encryption=psk2;
  uci set wireless.wlan_iot.key=...; uci commit wireless; wifi reload` — then check
  `logread | grep -c 'Hardware restart'` stays 0 and `dmesg | grep -ci 'out of memory'`.
- **Change guest speed:** edit `/etc/nftables.d/20-guest-qos.nft` (5 Mbps ≈
  610 kbytes/s; scale linearly), then `fw4 reload`.
- **Per-device guest limit** (instead of total): replace the policer with an
  nftables `meter` keyed on the client IP.
- **Re-apply the whole config from scratch:** run `apply-config.sh`'s body (it's
  the canonical VLAN+firewall+wireless setup). Reassign ports there if needed.
- **Rebuild firmware:** `build.sh` locally (Ubuntu/WSL on D:, ~30–45 min) or push
  to trigger the GitHub Actions workflow (~2 h). Keep it 5 GHz-only + the DTS in
  `files/` (kernel-5.15 syntax: `mediatek,mtd-eeprom` + nvmem MACs).
- **Restore Padavan** (abandon OpenWrt): `cat backups/mtd6_Firmware_Stub.bin |
  ssh root@ROUTER 'mtd -r write - firmware'` — or via Breed. (Padavan = great WiFi
  but NO VLAN segmentation; that's why we're on OpenWrt.)

## 6. Safe-change pattern for anything that restarts the network

Risky remote changes (network/bridge/port edits) can lock you out. Use an
auto-rollback: back up `/etc/config`, launch a detached watchdog that reverts +
reboots unless you confirm, then apply detached:
```sh
cp -a /etc/config /etc/config.bak
cat > /tmp/rb.sh <<'RB'
#!/bin/sh
sleep 300
[ -f /tmp/ok ] && exit 0
rm -rf /etc/config; cp -a /etc/config.bak /etc/config; sync; reboot
RB
chmod +x /tmp/rb.sh
start-stop-daemon -S -b -x /bin/sh -- /tmp/rb.sh   # NOT setsid (absent)
# ... apply uci changes; uci commit; /etc/init.d/network restart ...
```
Reconnect (IPv6 link-local!), verify, then `touch /tmp/ok` to cancel the rollback.

## 7. Repo / files

- `apply-config.sh` — canonical VLAN + firewall + DHCP + wireless setup.
- `apply-patch.sh`, `config.seed`, `files/mt7621_zte_e8820v2.dts`,
  `files/e8820v2.mk`, `files/rc.local`, `files/guest-qos.nft` — build inputs.
- `build.sh` — standalone local build. `.github/workflows/build.yml` — cloud build.
- Backups: `d:\Projects\openwrt-router\backups\` (Padavan fw, factory, bootloader,
  `padavan-nvram.txt`).
