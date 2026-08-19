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

- **Wi-Fi is disabled on the router — run it on separate APs.** This board has
  only 64MB RAM. Running the full VLAN + firewall + dnsmasq stack already uses
  ~38MB; adding the MT76 radios pushes it into OOM and, critically, an endless
  `ieee80211 phyN: Hardware restart was requested` loop on the MT7612 (5GHz) —
  the radio resets ~once per second and is unusable. Both `mt7603e` (2.4GHz) and
  `mt7612e` (5GHz) also have flaky PCIe ROM handshakes on cold boot
  (`Timeout waiting for ROM code`). The reliable architecture is to use this
  device purely as a router/firewall/VLAN gateway and let dedicated access points
  (with their own RAM) serve all SSIDs, tagged onto the VLANs over a trunk port.
  Both radios are therefore left `disabled` in `/etc/config/wireless` and
  `/etc/rc.local` is a no-op.
- `pcie_aspm=off` is set on the kernel command line via the DTS `chosen` node
  (kept from debugging the radio bring-up; harmless and left in place).
- **IPv6 is disabled** (`network.wan6` removed, `odhcpd` stopped) to reclaim RAM;
  re-enable if you have native IPv6 and spare memory.
- If you ever want to experiment with radios on the router anyway, expect
  instability; keep it to a single AP at HT20/VHT40 and watch `logread` for
  "Hardware restart".

## Flashing onto a memory-constrained unit

`sysupgrade`/LuCI stage the whole image in tmpfs, which can OOM a 64MB device.
If that happens, stream the image straight to flash instead (no staging):

```sh
cat openwrt-*-zte_e8820v2-squashfs-sysupgrade.bin | ssh root@ROUTER 'mtd -r write - firmware'
```
