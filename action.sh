#!/system/bin/sh
# WG Shield Arm64 - Action button in the manager: tunnel on/off
MODDIR=${0%/*}
. "$MODDIR/sh/common.sh"
settings_load
if [ -n "$S_ACTIVE" ]; then
    echo "Turning the tunnel off (direct connection)..."
    out=$(sh "$MODDIR/ctl.sh" down)
else
    echo "Turning the tunnel on..."
    out=$(sh "$MODDIR/ctl.sh" up)
fi
# printf, not echo: an error or reason can quote a tunnel file's text, and
# mksh's echo (/system/bin/sh) reads its backslashes
val() { printf '%s\n' "$out" | sed -n "s/^$1=//p"; }
st=$(val state); tn=$(val tunnel); er=$(val error); hs=$(val handshake_age)
[ -n "$er" ] && { printf '%s\n' "Error: $er"; exit 0; }
case "$st" in
    up) printf '%s\n' "Protected: $tn (handshake ${hs}s ago)" ;;
    handshaking) printf '%s\n' "Connecting: $tn - check again in a few seconds" ;;
    off) echo "Off - direct connection" ;;
    *) printf '%s\n' "State: $st $(val reason)" ;;
esac
