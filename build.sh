#!/usr/bin/env bash
# WG Shield Arm64 - build the `wg` tool (wireguard-tools) as a static arm64 binary.
# Needs: curl, tar, make, zig (0.11 or newer). Run in WSL:  bash build.sh
# Result: ./out/wg  -> copy to <module>/system/bin/wg
set -euo pipefail

VER="${WG_TOOLS_VERSION:-1.0.20250521}"
ZIG="${ZIG:-zig}"
cd "$(dirname "$(readlink -f "$0")")"

command -v "${ZIG%% *}" >/dev/null || { echo "zig not found (set ZIG=/path/to/zig)"; exit 1; }

SRC="wireguard-tools-$VER"
if [ ! -d "$SRC" ]; then
    echo "==> downloading wireguard-tools v$VER"
    curl -fL -o "$SRC.tar.gz" "https://codeload.github.com/WireGuard/wireguard-tools/tar.gz/refs/tags/v$VER"
    tar xzf "$SRC.tar.gz"
fi

echo "==> building (aarch64-linux-musl, static)"
make -C "$SRC/src" clean >/dev/null
make -C "$SRC/src" -s CC="$ZIG cc -target aarch64-linux-musl" LDFLAGS="-static -s" \
     PLATFORM=linux WITH_WGQUICK=no wg

mkdir -p out
cp "$SRC/src/wg" out/wg
chmod 755 out/wg
echo "==> done"
file out/wg 2>/dev/null || true
sha256sum out/wg
