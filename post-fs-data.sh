#!/system/bin/sh
# WG Shield Arm64 - early boot: reset runtime state; if a tunnel is on and the
# kill switch is on, block traffic until the tunnel is up (no leak at boot).
MODDIR=${0%/*}
. "$MODDIR/sh/common.sh"
. "$MODDIR/sh/tunnels.sh"
. "$MODDIR/sh/net.sh"

mkdir -p "$STATE" "$TUNDIR"
chmod 700 "$DATA" "$TUNDIR"
rm -rf "$STATE/lock" "$STATE"/import.* "$STATE"/setconf.*
rm -f "$STATE/status" "$STATE/pause_until" "$STATE/loaded" "$STATE/tunnel.info" \
      "$STATE/rules.key" "$STATE/rules.sig" "$STATE/up_since" "$STATE/last_state" \
      "$STATE/watchdog.pid" "$STATE/boot.log"
settings_load
if [ -n "$S_ACTIVE" ] && [ "$S_KILLSWITCH" = 1 ]; then
    boot_guard
    wlog INFO "boot: kill switch guard on until tunnel $S_ACTIVE is up"
fi
