# ZTE E8820V2 — SSH Troubleshooting Playbook

Practical reference for diagnosing this router over SSH. Pairs with
[AGENT-NOTES.md](AGENT-NOTES.md) (full config + reconfig recipes). Distilled from
the build/debug investigation, Aug 2026.

---

## Connecting

```sh
ssh root@172.30.10.1                              # normal (password: @Hammadar4549)
ssh root@fe80::7e39:55ff:fe61:1a8e%<ifindex>      # fallback — works even if IPv4 is broken
```
- The router's IPv6 link-local (`fe80::7e39:55ff:fe61:1a8e`) is derived from its LAN
  MAC and never changes. On Windows find `<ifindex>` with `Get-NetAdapter -Name
  Ethernet` — **it changes** after network churn, so re-read it each time.
- **From the corporate-WARP laptop:** if SSH/ping fails, WARP is probably grabbing
  the LAN. Check `Find-NetRoute -RemoteIPAddress 172.30.10.1` in PowerShell — the
  `InterfaceAlias` must be your Ethernet, **not** `CloudflareWARP`. If it's WARP,
  see "Can't reach the router from the WARP laptop" below.

## One-shot health check (paste over SSH)

```sh
. /etc/openwrt_release; echo "== $DISTRIB_RELEASE =="; uptime
echo "-- mem --"; free | sed -n 2p; grep MemAvailable /proc/meminfo
echo "-- oom --"; dmesg | grep -c -i 'out of memory'
echo "-- wifi --"; iw dev | grep -E 'ssid|channel'
echo "-- 5G restart loop? (should stay 0) --"; logread | grep -c 'Hardware restart'
echo "-- net --"; ip -4 addr show br-lan | grep -o 'inet [0-9.]*'; ip -4 addr show br-guest | grep -o 'inet [0-9.]*'
echo "-- wan/inet --"; ip -4 addr show wan | grep -o 'inet [0-9.]*'; ping -c1 -W2 8.8.8.8 >/dev/null && echo INET_OK || echo INET_FAIL
echo "-- dns upstreams --"; uci get dhcp.@dnsmasq[0].server
```
Healthy baseline: load < 1, `MemAvailable` ~0.9–1.5 MB, restart count 0, both SSIDs
listed at `width: 40 MHz`, `INET_OK`.

## Cheat-sheet by area

**System / memory (64 MB is tight — watch this first)**
```sh
free; grep -E 'MemAvailable|SwapFree' /proc/meminfo   # available < ~300 kB = danger
dmesg | grep -i 'out of memory'                       # OOM-killer events
top -bn1 | head -15                                    # CPU/mem hogs
cat /proc/loadavg
```

**Wi-Fi / radios (5 GHz-only build; radio0 = mt76x2)**
```sh
iw dev | grep -E 'Interface|ssid|channel|type'        # APs up? which width?
ls /sys/class/ieee80211/                               # PHYs present?
logread | grep -iE 'hostapd|mt76|wifi' | tail -20
logread | grep -c 'Hardware restart'                   # >0 and climbing = VHT80 bug
ubus call network.wireless status | grep -E '"up"|retry_setup_failed'
uci show wireless | grep -E 'ssid|channel|htmode|disabled|path'
wifi reload                                             # re-apply wireless config
```

**Network / VLANs (flat: br-lan all ports + br-guest wifi-only)**
```sh
ip -4 addr; ip route
cat /tmp/dhcp.leases                                   # who has a lease
bridge vlan show                                       # usually EMPTY (HW-offloaded switch)
for p in lan1 lan2 lan3 lan4 wan; do echo $p carrier=$(cat /sys/class/net/$p/carrier); done
```

**DNS (AdGuard 172.30.10.17 primary + public fallback)**
```sh
uci get dhcp.@dnsmasq[0].server                        # expect: 172.30.10.17 1.1.1.1 8.8.8.8
nslookup openwrt.org 127.0.0.1                          # router resolves? (fallback works)
nslookup proxmox.koretux.space 172.30.10.17            # AdGuard has local records?
/etc/init.d/dnsmasq status; logread | grep -i dnsmasq | tail
```

**Firewall (fw4/nftables)**
```sh
fw4 reload                                              # re-apply; watch for warnings
nft list ruleset | grep -A4 guest_qos                  # guest 5 Mbps cap present?
uci show firewall | grep -E 'zone|forwarding'
```

**Logs**
```sh
logread | tail -50 ; logread -e mt76 ; dmesg | tail -50
```

## Symptom → cause → fix (the known gotchas)

| Symptom | Cause | Fix |
|---|---|---|
| 5 GHz keeps dropping; `logread` full of `phyN: Hardware restart` (~1/s) | Radio set to **VHT80/80 MHz** — DMA too big for 64 MB | `uci set wireless.radio0.htmode='VHT40'; uci commit wireless; wifi reload`. **Never** VHT80. |
| Router OOM-reboots; APs won't come up; `MemAvailable` tiny | Too much for 64 MB (3+ APs, VLANs, extra pkgs) | Keep flat + **≤2 APs**; no `opkg install`; check `dmesg | grep -i oom` |
| 2.4/5 GHz PHY missing after cold boot | MT76 PCIe ROM handshake fails | Handled by `/etc/rc.local` (re-bind + reconcile). Manual: `echo 1e140000.pcie >/sys/bus/platform/drivers/mt7621-pci/unbind; sleep1; echo 1e140000.pcie >/sys/bus/platform/drivers/mt7621-pci/bind; sleep5; wifi up` |
| Can't reach router from the WARP laptop | WARP routes the LAN subnet into the corporate tunnel | `Find-NetRoute -RemoteIPAddress 172.30.10.1` — if `CloudflareWARP`, the subnet is in WARP's Split-Tunnel **Include** list (or not excluded). Remove `172.30.10.0/24` from Include; use IPv6 link-local meanwhile |
| `koretux.space` won't resolve on the laptop (`ERR_NAME_NOT_RESOLVED`) | WARP overrides DNS (its DoH proxy `127.0.2.2/3`) | Cloudflare Zero Trust → WARP → **Local Domain Fallback**: `koretux.space → 172.30.10.17`. AdGuard itself is fine (test `nslookup … 172.30.10.17`) |
| No internet when the minipc/AdGuard is down | dnsmasq has no working upstream | Ensure `uci get dhcp.@dnsmasq[0].server` = `172.30.10.17 1.1.1.1 8.8.8.8` with `strictorder=1`, `noresolv=1` |
| Locked out after a network/bridge change | config change dropped your route | Reconnect over **IPv6 link-local**; if truly stuck, the change should have used the rollback pattern (AGENT-NOTES §6); last resort = Breed |

## Recovery

- **Risky change safety net:** use the rollback watchdog in AGENT-NOTES §6 (back up
  `/etc/config`, auto-revert+reboot unless you `touch /tmp/ok`). `setsid` is absent —
  detach with `start-stop-daemon -S -b -x /bin/sh -- /tmp/script.sh`.
- **Reapply the whole config:** run `apply-config.sh` (flat LAN + guest + 2 APs + DNS).
- **Restore stock Padavan:** `cat ../backups/mtd6_Firmware_Stub.bin | ssh root@ROUTER 'mtd -r write - firmware'`.
- **Bricked / no boot:** Breed bootloader — hold **reset** at power-on, browse to
  `192.168.1.1`, flash a backup/image.

## Quick facts

- OpenWrt **23.05.6**, 5 GHz-only. LAN **172.30.10.1/24** (all ports, flat), guest
  **172.30.20.1/24** (isolated, 5 Mbps). SSIDs **Alfarel-Wifi** (WPA2) +
  **Alfarel-Wifi-Guest** (open, isolated). AdGuard **172.30.10.17**. Root pw
  `@Hammadar4549`. IPv6 disabled. See AGENT-NOTES.md for the rest.
