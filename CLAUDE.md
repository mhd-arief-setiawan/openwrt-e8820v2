# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

This is **not a software codebase** — it's a workspace for building custom OpenWrt
firmware for, and remotely managing, one physical router: a **ZTE E8820V2**
(MT7621A, 16 MB flash, **64 MB RAM**, MT7612E 5 GHz radio). The router runs a
custom **OpenWrt 23.05.6, 5 GHz-only** build as an all-in-one router + firewall +
WiFi AP. Design is **flat** (one LAN subnet, no VLANs) — the earlier 5-VLAN scheme
was dropped because 64 MB couldn't run it alongside WiFi.

**Read [build-repo/AGENT-NOTES.md](build-repo/AGENT-NOTES.md) before doing anything
to the router.** It is the authoritative runbook: full config, credentials, the
hard-won hardware quirks, reconfiguration recipes, and the safe-change/rollback
pattern. For diagnosing a live problem over SSH, use
[build-repo/TROUBLESHOOTING.md](build-repo/TROUBLESHOOTING.md) (connect steps,
one-shot health check, command cheat-sheet, symptom→cause→fix, recovery). This
file is only the orientation layer.

## Layout

- `build-repo/` — git repo (GitHub: `mhd-arief-setiawan/openwrt-e8820v2`) that
  **builds the firmware image** and holds the **runtime config**:
  - `apply-patch.sh` adds E8820V2 device support to an OpenWrt tree (DTS +
    image recipe + LED/boot files from `files/`).
  - `config.seed` + `.github/workflows/build.yml` define the (5 GHz-only, slim)
    build; `build.sh` does the same build locally.
  - `apply-config.sh` — the canonical live config applied over SSH: flat LAN
    172.30.10.0/24 (all ports) + an isolated, 3 Mbps-capped guest network + two
    5GHz APs (Alfarel-Wifi, Alfarel-Wifi-Guest). Shapes the running router,
    separate from the firmware image.
  - `files/` — build inputs baked into the image: `mt7621_zte_e8820v2.dts`
    (kernel-5.15 syntax), `e8820v2.mk`, `rc.local` (boot-time radio recovery),
    `guest-qos.nft` (guest rate-limit).
- `backups/` — **recovery**: original Padavan firmware, factory/WiFi-calibration,
  bootloader, and `padavan-nvram.txt`. Breed bootloader is on the device.
- `firmware/` — downloaded/built `.bin` images.
- `home-network-design.html` — the VLAN design doc (published artifact).

## Firmware vs. live config — two separate layers

1. **The image** (`build-repo` build) contains device support, packages, the DTS,
   and `/etc/rc.local`. Rebuilding + reflashing is only needed to change the
   kernel/packages/DTS.
2. **The live config** (VLANs, firewall, wireless, QoS) lives in the router's
   `/etc/config/*` + `/etc/nftables.d/`, applied via `apply-config.sh` and ad-hoc
   `uci` over SSH. Most reconfiguration is here — no rebuild needed.

## Common commands

```sh
# Connect to the router (prefer IPv6 link-local — survives IP changes + WARP):
ssh root@172.30.10.1                                 # pw: @Hammadar4549
ssh root@fe80::7e39:55ff:fe61:1a8e%<ifindex>         # Windows: Get-NetAdapter for ifindex (it changes!)

# Build the firmware image:
cd build-repo && ./build.sh                          # local (Ubuntu/WSL, ~30-45 min)
#   or: git push  → GitHub Actions workflow (~2 h)

# Flash an image (mtd streaming — sysupgrade/LuCI OOM this 64 MB device):
cat firmware/*-squashfs-sysupgrade.bin | ssh root@ROUTER 'mtd -r write - firmware'

# Restore stock Padavan firmware:
cat backups/mtd6_Firmware_Stub.bin | ssh root@ROUTER 'mtd -r write - firmware'
```

## Non-negotiable constraints (see AGENT-NOTES.md §3 for the full list + why)

- **5 GHz radio must be VHT40, never VHT80/80 MHz** — 80 MHz triggers an endless
  mt76 "Hardware restart" loop on this 64 MB board.
- **RAM is at its ceiling** (~0.5–2 MB free): max 2 WiFi SSIDs; do NOT `opkg
  install` heavy packages (even `opkg update` can OOM); use built-in **nftables**
  for QoS, never SQM/tc.
- **`setsid` is absent** — detach background jobs with
  `start-stop-daemon -S -b -x /bin/sh -- /tmp/script.sh` (or `sh /tmp/x.sh &`).
- **Any change that restarts networking can lock you out** — use the auto-rollback
  watchdog pattern in AGENT-NOTES.md §6 (long 20-min window), reconnect over IPv6 link-local.
- **Cloudflare WARP on the management PC routes ALL of 10/8, 172.16/12, 100.64/10
  into the corporate tunnel and blocks the PC's DHCP** — so the router (on 172.30.x)
  is only reachable from that PC if `172.30.0.0/16` is excluded in WARP's Split
  Tunnel, or from a non-WARP device / with WARP paused. Only 192.168.x escapes WARP.
