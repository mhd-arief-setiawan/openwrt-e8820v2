#!/bin/bash
# Standalone local build of OpenWrt 23.05 for ZTE E8820V2 (5GHz-only, slim).
# Run on any Debian/Ubuntu Linux with ~40GB free and internet:
#   ./build.sh
# On a 6-core+ machine this is ~30-45 min (first run) vs ~2h on GitHub Actions.
# Works as-is in a GitLab CI job or a Proxmox build VM.
set -euo pipefail

VERSION="${OPENWRT_VERSION:-v23.05.6}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JOBS="$(nproc)"

echo ">>> Installing build dependencies (needs sudo)…"
if command -v apt-get >/dev/null; then
  sudo apt-get update
  sudo apt-get install -y build-essential clang flex bison g++ gawk gcc-multilib \
    g++-multilib gettext git libncurses-dev libssl-dev python3-setuptools rsync \
    swig unzip zlib1g-dev file wget ccache
fi

if [ ! -d openwrt ]; then
  echo ">>> Cloning OpenWrt $VERSION…"
  git clone --depth 1 --branch "$VERSION" https://github.com/openwrt/openwrt.git openwrt
fi

echo ">>> Applying E8820V2 device patch…"
"$SCRIPT_DIR/apply-patch.sh" openwrt

echo ">>> Updating feeds…"
cd openwrt
./scripts/feeds update -a
./scripts/feeds install -a

echo ">>> Configuring…"
cp "$SCRIPT_DIR/config.seed" .config
echo 'CONFIG_CCACHE=y' >> .config
make defconfig
grep CONFIG_TARGET_ramips_mt7621_DEVICE_zte_e8820v2=y .config

echo ">>> Downloading sources…"
make download -j"$JOBS" || make download -j1 V=s

echo ">>> Building with $JOBS jobs…"
make -j"$JOBS" || make -j1 V=s

echo ">>> Done. Images:"
ls -la bin/targets/ramips/mt7621/*.bin
