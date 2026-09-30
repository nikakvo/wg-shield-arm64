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
st=$(echo "$out" | sed -n 's/^state=//p')
tn=$(echo "$out" | sed -n 's/^tunnel=//p')
er=$(echo "$out" | sed -n 's/^error=//p')
hs=$(echo "$out" | sed -n 's/^handshake_age=//p')
[ -n "$er" ] && { echo "Error: $er"; exit 0; }
case "$st" in
    up) echo "Protected: $tn (handshake ${hs}s ago)" ;;
    handshaking) echo "Connecting: $tn - check again in a few seconds" ;;
    off) echo "Off - direct connection" ;;
    *) echo "State: $st $(echo "$out" | sed -n 's/^reason=//p')" ;;
esac
