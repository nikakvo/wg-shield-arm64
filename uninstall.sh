#!/system/bin/sh
# WG Shield Arm64 - remove the tunnel, our rules and all data (tunnel files hold private keys)
MODDIR=${0%/*}
. "$MODDIR/sh/common.sh"
. "$MODDIR/sh/tunnels.sh"
. "$MODDIR/sh/net.sh"
teardown
rm -rf "$DATA" "$STATE"
rm -f "$CONF" "$CONF".tmp.*
