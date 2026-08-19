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
