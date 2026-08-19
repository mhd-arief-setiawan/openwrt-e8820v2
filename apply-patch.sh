#!/bin/bash
# Add ZTE E8820V2 device support to an OpenWrt source tree.
set -euo pipefail

OPENWRT_DIR="${1:?usage: apply-patch.sh <openwrt-dir>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 1. Device tree
cp "$SCRIPT_DIR/files/mt7621_zte_e8820v2.dts" \
   "$OPENWRT_DIR/target/linux/ramips/dts/mt7621_zte_e8820v2.dts"

# 2. Image recipe
cat "$SCRIPT_DIR/files/e8820v2.mk" >> "$OPENWRT_DIR/target/linux/ramips/image/mt7621.mk"

# 3. LED defaults (insert case before the closing esac)
python3 - "$OPENWRT_DIR/target/linux/ramips/mt7621/base-files/etc/board.d/01_leds" <<'EOF'
import sys

path = sys.argv[1]
case = (
    "zte,e8820v2)\n"
    "\tucidef_set_led_netdev \"sys\" \"SYS_LED\" \"white:sys\" \"eth0\" \"tx rx\"\n"
    "\tucidef_set_led_timer \"power\" \"POWER_LED\" \"white:power\" \"100\" \"8000\"\n"
    "\t;;\n"
)
lines = open(path).read().splitlines(keepends=True)
idx = max(i for i, l in enumerate(lines) if l.strip() == "esac")
lines.insert(idx, case)
open(path, "w").write("".join(lines))
print("01_leds patched")
EOF

# 4. Boot-time 2.4GHz (MT7603E) recovery, baked into the image rootfs.
#    The MT7603E fails its PCIe ROM handshake on cold boot; this rc.local
#    re-binds the MT7621 PCIe controller once to recover it. It is self-gating
#    (acts only when mt7603e failed), so it is harmless on other boards.
mkdir -p "$OPENWRT_DIR/files/etc"
cp "$SCRIPT_DIR/files/rc.local" "$OPENWRT_DIR/files/etc/rc.local"
chmod +x "$OPENWRT_DIR/files/etc/rc.local"

grep -q "zte_e8820v2" "$OPENWRT_DIR/target/linux/ramips/image/mt7621.mk"
grep -q "zte,e8820v2" "$OPENWRT_DIR/target/linux/ramips/mt7621/base-files/etc/board.d/01_leds"
test -x "$OPENWRT_DIR/files/etc/rc.local"
echo "E8820V2 patch applied OK"
