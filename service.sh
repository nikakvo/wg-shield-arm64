#!/system/bin/sh
# WG Shield Arm64 - watchdog: every tick it brings the tunnel to the wanted
# state, follows network changes and repairs rules (fast ticks after boot).
MODDIR=${0%/*}
. "$MODDIR/sh/common.sh"
. "$MODDIR/sh/tunnels.sh"
. "$MODDIR/sh/net.sh"

mkdir -p "$STATE"
old=$(cat "$STATE/watchdog.pid" 2>/dev/null)
if [ -n "$old" ] && [ "$old" != $$ ] && kill -0 "$old" 2>/dev/null && grep -q service.sh "/proc/$old/cmdline" 2>/dev/null; then
    exit 0
fi
echo $$ > "$STATE/watchdog.pid"
QUIET_ON_SHUTDOWN=1
wlog INFO "watchdog started (pid $$)"

n=0
while :; do
    if shutting_down; then wlog INFO "watchdog: shutdown"; exit 0; fi
    if lock_try; then
        wgs_tick
        rc=$?
        lock_release
        epoch_now > "$STATE/tick"
        if [ "$rc" = 2 ]; then exit 0; fi
    fi
    n=$((n + 1))
    if [ "$n" -lt 30 ]; then sleep 2; else sleep "${WGS_TICK:-$TICK}"; fi
done
