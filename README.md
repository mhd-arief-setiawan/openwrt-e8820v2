# OpenWrt for ZTE E8820V2

Builds official OpenWrt **v24.10.8** with device support for the ZTE E8820V2
(MT7621A, 16MB SPI-NOR, 64MB RAM, MT7603E 2.4GHz + MT7612E 5GHz).

Device support files are taken from [siwind/openwrt](https://github.com/siwind/openwrt)
(an OpenWrt mirror carrying this device) and applied as a patch on top of the
stable release tag.

## Output

The GitHub Actions workflow produces:

- `openwrt-24.10.8-ramips-mt7621-zte_e8820v2-squashfs-sysupgrade.bin` — flash
  this via the Breed bootloader web recovery (firmware, offset auto/0x50000)
  or from an existing OpenWrt install via sysupgrade.
- `sha256sums`, package manifest, and `config.buildinfo`.

Includes LuCI web interface and zram-swap (helpful on 64MB RAM).

## What this build is

OpenWrt **23.05.6** (kernel 5.15 — lighter than 24.10's 6.6, which matters on
64MB), **5GHz-only** (`kmod-mt76x2`, no `kmod-mt7603`). It runs as a full
all-in-one router: routing + firewall + VLANs **and** a stable 5GHz AP.

`apply-config.sh` is the runtime config applied on top (5 VLANs + firewall +
DHCP + the 5GHz AP); `files/rc.local` handles the boot-time radio recovery.

## Hardware notes / quirks (learned the hard way)

- **5GHz must run at VHT40 (40 MHz), not VHT80.** This is the critical one. At
  80 MHz the mt76 driver's DMA buffers are too big for the 64MB board and the
  MT7612 falls into an endless `ieee80211 phyN: Hardware restart was requested`
  loop (~1/sec, unusable). At **VHT40 it is rock-stable (0 restarts)** and still
  delivers ~200–300 Mbps. `apply-config.sh` sets `htmode=VHT40`. Do **not** set
  VHT80/HE80.
- **On both 24.10 and 23.05 the width limit is the same** — it's a memory/DMA
  constraint, not a kernel-version bug, so a newer/older OpenWrt won't unlock
  VHT80 here. 23.05 is used because its lighter kernel leaves a bit more RAM.
- **5GHz cold-boot recovery.** The MT7612 intermittently fails its PCIe ROM
  handshake on cold boot; `files/rc.local` re-binds the MT7621 PCIe controller
  when the PHY is missing, then reconciles the radio to its PHY by driver (the
  PCI path shifts between boots) and brings the AP up. `pcie_aspm=off` is set via
  the DTS `chosen` node.
- **2.4GHz is intentionally omitted** (`kmod-mt7603` not built) — not needed, and
  it saves a little RAM.
- **IPv6 is disabled** (`network.wan6` removed, `odhcpd` stopped) to reclaim RAM.
- **RAM is at its limit.** With 5 VLANs + the 5GHz AP, free memory is only ~0.5–2
  MB (zram-swap cushions it). It runs stably, but avoid heavy extra packages; if
  you hit instability under load, dropping to 3 VLANs frees headroom.

## Flashing (memory-safe)

`sysupgrade`/LuCI stage the whole image in tmpfs and OOM this 64MB device. Stream
straight to flash instead (factory-fresh):

```sh
cat openwrt-*-zte_e8820v2-squashfs-sysupgrade.bin | ssh root@ROUTER 'mtd -r write - firmware'
```
