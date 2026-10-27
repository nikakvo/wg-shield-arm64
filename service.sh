#!/system/bin/sh
# WG Shield Arm64 - watchdog: every tick it brings the tunnel to the wanted
# state, follows network changes and repairs rules (fast ticks after boot).
#
# Network changes are not waited for: `ip monitor rule` wakes the watchdog
# the moment netd changes the default network (rule 31000), adds or removes
# a network (16000) or an Android VPN (13000). The tick runs as soon as
# netd has finished the change (nothing new for 0.2 s); a change that comes
# during the tick wakes it again at once. Without the monitor
# (it failed to start) the watchdog simply ticks every 10 s as before.
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

# ---- network events -------------------------------------------------------------
EVT="$STATE/events"
MON_PID=""          # subshell that runs `ip monitor` and reports when it ends
MON_TRIES=0
mon_stop() {
    p=$(cat "$STATE/monitor.pid" 2>/dev/null)
    [ -n "$MON_PID" ] && kill "$MON_PID" 2>/dev/null
    [ -n "$p" ] && grep -q monitor "/proc/$p/cmdline" 2>/dev/null && kill "$p" 2>/dev/null
    MON_PID=""; rm -f "$STATE/monitor.pid"
}
mon_start() {
    mon_stop    # also one left over from an earlier watchdog (killed, not stopped)
    rm -f "$EVT"
    mkfifo -m 600 "$EVT" 2>/dev/null || return 1
    exec 3<>"$EVT" || return 1           # read+write: opening never blocks
    (
        trap - EXIT TERM INT
        "$IP" monitor rule >&3 2>/dev/null &
        echo $! > "$STATE/monitor.pid"
        wait
        echo "MONITOR-EXIT" >&3
    ) &
    MON_PID=$!
    _w=0
    while [ ! -s "$STATE/monitor.pid" ] && [ "$_w" -lt 10 ]; do sleep 0.1 2>/dev/null || sleep 1; _w=$((_w + 1)); done
    sleep 0.1 2>/dev/null
    p=$(cat "$STATE/monitor.pid" 2>/dev/null)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}
mon_alive() { [ -n "$MON_PID" ] && kill -0 "$MON_PID" 2>/dev/null; }
# a netd rule that means "the networks changed"
evt_relevant() {
    case "${1#Deleted }" in 13000:*|16000:*|31000:*) return 0 ;; esac
    return 1
}
# wait_event SECONDS - 0 when a network change woke us (netd is done with
# it: nothing new for 0.2 s), 1 after the time
wait_event() {
    if ! mon_alive; then
        # restart a dead monitor a few times, then fall back to plain ticks
        if [ "$MON_TRIES" -lt 3 ]; then
            MON_TRIES=$((MON_TRIES + 1))
            if mon_start; then
                wlog INFO "watching network changes (ip monitor, pid $(cat "$STATE/monitor.pid" 2>/dev/null))"
            else
                mon_stop
                [ "$MON_TRIES" = 3 ] && wlog WARN "cannot watch network changes - checking every ${TICK} s only"
            fi
        fi
        mon_alive || { sleep "$1"; return 1; }
    fi
    _i=0
    while read -r -t "$1" _l <&3; do
        if [ "$_l" = MONITOR-EXIT ]; then
            wlog WARN "network change watch stopped - starting it again"
            MON_PID=""; return 0
        fi
        if evt_relevant "$_l"; then
            capture_new "$_l"
            # netd changes several rules in a row: wait until it is done
            _i=0
            while [ "$_i" -lt 50 ] && read -r -t 0.2 _l <&3; do capture_new "$_l"; _i=$((_i + 1)); done
            return 0
        fi
        _i=$((_i + 1)); [ "$_i" -ge 50 ] && return 1   # a storm of other rules: tick anyway
    done
    return 1
}
# a network netd just created goes through the tunnel at once (fast_capture
# in sh/net.sh), not only at the next tick - no lock: it only adds rules
capture_new() {
    case "$1" in 16000:*) fast_capture "$1" ;; esac
}
trap 'mon_stop' EXIT
trap 'mon_stop; exit 0' TERM INT

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
    if [ "$n" -lt "${WGS_FAST:-30}" ]; then t=2; else t=${WGS_TICK:-$TICK}; fi
    wait_event "$t"
done
