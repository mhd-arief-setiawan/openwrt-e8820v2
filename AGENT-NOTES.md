# ZTE E8820V2 — Agent Handoff Notes

Runbook for reconfiguring this router. Read this **before** touching it — several
non-obvious constraints will bite you otherwise. Last verified: 2026-08-20.

---

## 1. What this device is

- **ZTE E8820V2**: MT7621A SoC, **16 MB SPI-NOR flash, 64 MB RAM**, 5× gigabit
  ports, MT7603E (2.4 GHz, **not used**) + **MT7612E (5 GHz)** radios.
- Running custom **OpenWrt 23.05.6, 5 GHz-only** (kmod-mt7603 omitted).
  Build/source: `mhd-arief-setiawan/openwrt-e8820v2` (local: `build-repo/`).
- **Breed bootloader present** → bad flash recoverable (hold reset at power-on →
  192.168.1.1). Original Padavan fw + factory + bootloader backups in
  `../backups/`.

## 2. Access

| | |
|---|---|
| LuCI / SSH | `root` / `@Hammadar4549` |
| Router LAN IP | **172.30.10.1** |
| Reliable mgmt channel | IPv6 link-local `fe80::7e39:55ff:fe61:1a8e%<ifindex>` |

The router LAN MAC `7c:39:55:61:1a:8e` → link-local `fe80::7e39:55ff:fe61:1a8e`,
stable across IP changes. On Windows the `<ifindex>` **changes** after network
churn — always re-read it: `Get-NetAdapter -Name Ethernet`.

## 3. ⚠️ Critical constraints (learned the hard way — do not relearn)

1. **5 GHz MUST be VHT40, never VHT80/80 MHz.** 80 MHz DMA buffers exceed 64 MB →
   endless `ieee80211 phyN: Hardware restart` loop. VHT40 = stable, ~200–300 Mbps.
2. **RAM is the hard limit.** The old 5-VLAN design left ~0.2 MB free and was
   unstable. The current **flat single-LAN design** leaves ~0.9–1.4 MB with 2 APs.
   Keep it flat; **2 APs is the max**; never `opkg install` heavy pkgs (even
   `opkg update` can OOM); use **nftables** for QoS, never SQM/tc.
3. **WARP on the management PC captures almost all private space.** The user's
   corporate Cloudflare WARP routes **all of `10.0.0.0/8`, `172.16.0.0/12`, and
   `100.64/10`** into the tunnel, AND blocks the PC's DHCP. Only **`192.168.0.0/16`**
   is left alone by default. We use `172.30.x` at the user's request — it is only
   reachable from the WARP'd PC if `172.30.0.0/16` is added to WARP's Split-Tunnel
   **exclude** list (Cloudflare Zero Trust admin). Otherwise manage the router from
   a non-WARP device (phone on Wi-Fi), over IPv6 link-local, or with WARP paused.
4. **`setsid` is absent.** Detach jobs with a leading background + sleep, launched
   from a live SSH session, e.g. `sh /tmp/x.sh >/tmp/x.log 2>&1 &` (it survives
   long enough to commit + restart), or `start-stop-daemon -S -b -x /bin/sh -- /tmp/x.sh`.
5. **Flash with mtd streaming**, never sysupgrade/LuCI (they OOM staging in tmpfs):
   `cat img.bin | ssh root@ROUTER 'mtd -r write - firmware'`.
6. **Any change that restarts networking can lock you out** — use the rollback
   pattern (§6) and reconnect over IPv6 link-local.
7. **L2 is hardware-offloaded** → `bridge fdb show` is empty; find a device's port
   via `/sys/class/net/lanN/statistics/rx_packets` deltas.
8. **5 GHz cold-boot is flaky** → `/etc/rc.local` re-binds the PCIe controller when
   the mt76x2 PHY is missing and reconciles the radio path by driver.

## 4. Current configuration (flat, minimal)

- **Network:** one flat bridge `br-lan` over **all 4 LAN ports** (no VLANs),
  interface `lan` = **172.30.10.1/24**, DHCP .100–.249. WAN = DHCP client.
  Plus a **wifi-only guest bridge** `br-guest`, interface `guest` =
  **172.30.20.1/24**, DHCP.
- **Wi-Fi** (`radio0` = mt76x2 5 GHz, ch36, **VHT40**; path rewritten each boot by
  rc.local):
  - `wmain`: SSID **Alfarel-Wifi**, network `lan`, WPA2 (`@Hammadar4549`).
  - `wguest`: SSID **Alfarel-Wifi-Guest**, network `guest`, **open**, `isolate=1`.
- **Firewall:** default `lan`(accept)+`wan`(masq); added `guest` zone
  (input REJECT + allow DHCP/DNS, forward → wan only) so guests are internet-only,
  isolated from LAN.
- **Guest 5 Mbps cap:** `/etc/nftables.d/20-guest-qos.nft` — fw4 policer on
  `br-guest`, both directions (repo: `files/guest-qos.nft`).
- **IPv6 disabled** (`wan6` removed, `odhcpd` off) to save RAM.
- **Proxmox** is on a LAN port → give it `172.30.10.x` (static or DHCP).

## 5. Reconfiguration recipes

- **Change a Wi-Fi password:** `uci set wireless.wmain.key='NEW'; uci commit
  wireless; wifi reload`.
- **Change guest speed:** edit `/etc/nftables.d/20-guest-qos.nft` (5 Mbps ≈ 610
  kbytes/s; scale linearly) → `fw4 reload`.
- **Rebuild everything clean:** factory reset (`firstboot -y; reboot` → 192.168.1.1,
  WARP-safe → reliable window) then run `apply-config.sh` (the whole flat setup).
- **Rebuild firmware:** `build.sh` locally (Ubuntu/WSL on D:, ~30–45 min) or push
  → GitHub Actions (~2 h). Keep 5 GHz-only; DTS in `files/` is kernel-5.15 syntax.
- **Restore Padavan:** `cat ../backups/mtd6_Firmware_Stub.bin | ssh root@ROUTER
  'mtd -r write - firmware'`.

## 6. Safe-change pattern (network-restarting changes)

```sh
cp -a /etc/config /etc/config.bak
cat > /tmp/rb.sh <<'RB'
#!/bin/sh
sleep 1200
[ -f /tmp/ok ] && exit 0
rm -rf /etc/config; cp -a /etc/config.bak /etc/config; sync; reboot
RB
chmod +x /tmp/rb.sh
start-stop-daemon -S -b -x /bin/sh -- /tmp/rb.sh   # setsid is absent
# ...apply uci; uci commit; /etc/init.d/network restart...
```
Reconnect over IPv6 link-local, verify, then `touch /tmp/ok`. Use a **long window
(20 min)** — the WARP-flaky link makes canceling slow. Note: a reboot wipes /tmp,
which also kills the watchdog (so a clean reboot into the new config = safe).

## 7. Repo / files

- `apply-config.sh` — the canonical flat config (LAN + isolated 5 Mbps guest + 2 APs).
- `apply-patch.sh`, `config.seed`, `files/{mt7621_zte_e8820v2.dts, e8820v2.mk,
  rc.local, guest-qos.nft}` — build inputs. `build.sh` / workflow — build.
- `../backups/` — Padavan fw, factory (WiFi cal), bootloader, `padavan-nvram.txt`.
