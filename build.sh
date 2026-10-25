#!/usr/bin/env bash
# WG Shield Arm64 - build the `wg` and `awg` tools as static arm64 binaries.
#   wg  = wireguard-tools (plain WireGuard tunnels)
#   awg = amneziawg-tools (AmneziaWG tunnels), pinned to one commit
# Needs: curl or git, tar, make, zig. Run in WSL:  bash build.sh
# Result: ./out/wg and ./out/awg -> copy to <module>/system/bin/
# zig 0.16.0 gives the same files as the release (SHA-256 printed at the end):
#   wg  b460f9dddaa75b1293eefdd6f7152a30ccf3ffa19267968c52654efdbe056cd0
#   awg db3c9a3e384e8bf779fd72408db59b7e061ce214f570438f0e6a87f9fa559a04
set -euo pipefail

WG_VER="${WG_TOOLS_VERSION:-1.0.20250521}"
# amneziawg-tools 3.1.20260812 ("feat: add awg 3.1 params"). Pinned on purpose:
# change it only together with a test on a phone with the AmneziaWG kernel module.
AWG_SHA="${AWG_TOOLS_COMMIT:-ee0f0a9aa34ff0a0da4b3433b9512781cfe02843}"
ZIG="${ZIG:-zig}"
cd "$(dirname "$(readlink -f "$0")")"

command -v "${ZIG%% *}" >/dev/null || { echo "zig not found (set ZIG=/path/to/zig)"; exit 1; }
echo "==> zig $($ZIG version)"

# fetch <dir> <codeload url> <git url> <ref>
fetch() {
    [ -d "$1" ] && return 0
    echo "==> downloading $1"
    if curl -fL -o "$1.tar.gz" "$2" && mkdir -p "$1" && tar xzf "$1.tar.gz" -C "$1" --strip-components=1; then
        rm -f "$1.tar.gz"; return 0
    fi
    rm -rf "$1" "$1.tar.gz"
    echo "==> tarball failed, trying git"
    git clone -q "$3" "$1"
    git -C "$1" checkout -q "$4"
}

# build <src dir> <output name>
build() {
    echo "==> building $2 (aarch64-linux-musl, static)"
    make -C "$1/src" clean >/dev/null
    make -C "$1/src" -s CC="$ZIG cc -target aarch64-linux-musl" LDFLAGS="-static -s" \
         PLATFORM=linux WITH_WGQUICK=no wg
    mkdir -p out
    cp "$1/src/wg" "out/$2"
    chmod 755 "out/$2"
}

WG_SRC="wireguard-tools-$WG_VER"
fetch "$WG_SRC" "https://codeload.github.com/WireGuard/wireguard-tools/tar.gz/refs/tags/v$WG_VER" \
      https://github.com/WireGuard/wireguard-tools "v$WG_VER"
AWG_SRC="amneziawg-tools-${AWG_SHA:0:12}"
fetch "$AWG_SRC" "https://codeload.github.com/amnezia-vpn/amneziawg-tools/tar.gz/$AWG_SHA" \
      https://github.com/amnezia-vpn/amneziawg-tools "$AWG_SHA"

build "$WG_SRC" wg
build "$AWG_SRC" awg

echo "==> done"
file out/wg out/awg 2>/dev/null || true
sha256sum out/wg out/awg
