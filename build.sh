#!/usr/bin/env bash
# WG Shield Arm64 - build the `wg` and `awg` tools as static arm64 binaries.
#   wg  = wireguard-tools (plain WireGuard tunnels)
#   awg = amneziawg-tools (AmneziaWG tunnels), pinned to one commit
# Needs: curl or git, tar, make, zig. Run in WSL:  bash build.sh
# Result: ./out/wg and ./out/awg -> copy to <module>/system/bin/
# zig 0.16.0 gives the same files as the release (SHA-256 printed at the end):
#   wg  92efd615c43f6668826ee84338a05587b24e5ad5dc3a5586f9312ca825b827da
#   awg db3c9a3e384e8bf779fd72408db59b7e061ce214f570438f0e6a87f9fa559a04
set -euo pipefail

WG_VER="${WG_TOOLS_VERSION:-1.0.20260223}"
# amneziawg-tools 3.1.20260812 ("feat: add awg 3.1 params"). Pinned on purpose:
# change it only together with a test on a phone with the AmneziaWG kernel module.
AWG_SHA="${AWG_TOOLS_COMMIT:-ee0f0a9aa34ff0a0da4b3433b9512781cfe02843}"
ZIG="${ZIG:-zig}"
cd "$(dirname "$(readlink -f "$0")")"

command -v "${ZIG%% *}" >/dev/null || { echo "zig not found (set ZIG=/path/to/zig)"; exit 1; }
echo "==> zig $($ZIG version)"

# The sources are checked before they are used: the tarball by its SHA-256,
# the git fallback by its commit. A tarball that does not match is not used:
# the git fallback, checked by its commit, is taken instead. Another version
# (WG_TOOLS_VERSION / AWG_TOOLS_COMMIT) needs its own pins (WG_TAR_SHA256 /
# WG_COMMIT, AWG_TAR_SHA256).
WG_TAR_SHA256="${WG_TAR_SHA256:-859f8af03702db5e5c43f8ece77f5ebef40a2f4627c3e03997a031d4940ea9bc}"
WG_COMMIT="${WG_COMMIT:-49ce333da02056ae7b22ee2aeb6afe8aaed79b19}"
AWG_TAR_SHA256="${AWG_TAR_SHA256:-22438f231d39ea27e4bdc69707ec3103357f3cecc9ad3eecba18a61e5b39c9b9}"

# fetch <dir> <codeload url> <git url> <ref> <tarball sha256> <commit>
# The source goes to <dir>.part and is renamed to <dir> only once it is
# checked: a run that failed or was killed midway leaves no <dir> that the
# next run would take unchecked. A checked folder holds .wgs-checked with the
# pins it was checked against; an existing folder without it (left by an
# older build.sh, or placed by hand) or with other pins stops the build.
fetch() {
    if [ -d "$1" ]; then
        [ "$(cat "$1/.wgs-checked" 2>/dev/null)" = "$5 $6" ] && return 0
        echo "==> $1 exists but was not checked against the current pins (no or other .wgs-checked) - move it away and run again"
        exit 1
    fi
    rm -rf "$1.part"
    echo "==> downloading $1"
    if curl -fL -o "$1.tar.gz" "$2"; then
        got=$(sha256sum "$1.tar.gz" | cut -d' ' -f1)
        if [ "$got" = "$5" ]; then
            if mkdir -p "$1.part" && tar xzf "$1.tar.gz" -C "$1.part" --strip-components=1 &&
               printf '%s\n' "$5 $6" > "$1.part/.wgs-checked"; then
                mv "$1.part" "$1"; rm -f "$1.tar.gz"; return 0
            fi
        else
            # GitHub may build its archives anew (other bytes, same files):
            # the tarball is not used, the git checkout below is checked
            # against the pinned commit instead
            echo "==> $1.tar.gz: SHA-256 $got, expected $5 - not used"
        fi
    fi
    rm -rf "$1.part" "$1.tar.gz"
    echo "==> tarball failed, trying git (checked against commit $6)"
    git clone -q "$3" "$1.part"
    git -C "$1.part" checkout -q "$4"
    got=$(git -C "$1.part" rev-parse HEAD)
    if [ "$got" != "$6" ]; then
        rm -rf "$1.part"
        echo "==> $1: commit $got, expected $6 - not used"; exit 1
    fi
    printf '%s\n' "$5 $6" > "$1.part/.wgs-checked"
    mv "$1.part" "$1"
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
      https://github.com/WireGuard/wireguard-tools "v$WG_VER" "$WG_TAR_SHA256" "$WG_COMMIT"
AWG_SRC="amneziawg-tools-${AWG_SHA:0:12}"
fetch "$AWG_SRC" "https://codeload.github.com/amnezia-vpn/amneziawg-tools/tar.gz/$AWG_SHA" \
      https://github.com/amnezia-vpn/amneziawg-tools "$AWG_SHA" "$AWG_TAR_SHA256" "$AWG_SHA"

build "$WG_SRC" wg
build "$AWG_SRC" awg

echo "==> done"
file out/wg out/awg 2>/dev/null || true
sha256sum out/wg out/awg
