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

## Hardware notes / quirks

- **2.4GHz (MT7603E) cold-boot fix.** On this board the MT7603E fails its PCIe
  ROM handshake on a cold boot (`mt7603e: Timeout waiting for ROM code`), so the
  2.4GHz radio is missing after boot. A baked-in `/etc/rc.local` (see
  `files/rc.local`) re-binds the MT7621 PCIe host controller once at the end of
  boot, which recovers the radio; it then drops the stale pre-rebind PCI devices
  to reclaim RAM. The script is self-gating (runs only if the MT7603E failed) and
  backgrounded so it can never block boot. `pcie_aspm=off` is also set on the
  kernel command line via the DTS `chosen` node (necessary but not sufficient on
  its own).
- After the re-bind, both radios live in PCI domain `0001`. On a brand-new flash
  the firstboot-generated `/etc/config/wireless` may list only the 5GHz radio
  (the 2.4GHz PHY appears a few seconds later); if so, add/enable the 2.4GHz
  radio once in LuCI (Network → Wireless) — its path is
  `1e140000.pcie/pci0001:00/0001:00:00.0/0001:01:00.0`.
- **64MB RAM is tight** for 24.10 with two radios; zram-swap is included. Steady
  state is stable (idle load < 1), but avoid installing many heavy packages.

## Flashing onto a memory-constrained unit

`sysupgrade`/LuCI stage the whole image in tmpfs, which can OOM a 64MB device.
If that happens, stream the image straight to flash instead (no staging):

```sh
cat openwrt-*-zte_e8820v2-squashfs-sysupgrade.bin | ssh root@ROUTER 'mtd -r write - firmware'
```
