#!/system/bin/sh
# WG Shield Arm64 - early boot: reset runtime state; if a tunnel is on and the
# kill switch is on, block traffic until the tunnel is up (no leak at boot).
MODDIR=${0%/*}
. "$MODDIR/sh/common.sh"
. "$MODDIR/sh/tunnels.sh"
. "$MODDIR/sh/net.sh"

# r4: one folder - the first boot after an update moves the old files
layout_migrate
mkdir -p "$STATE" "$TUNDIR" "$LOGDIR"
chmod 700 "$DATA" "$TUNDIR"
rm -rf "$STATE/lock" "$STATE"/import.* "$STATE"/setconf.* "$STATE/test.lock" "$STATE"/testconf.*
rm -f "$STATE/test.progress"
rm -f "$STATE/status" "$STATE/pause_until" "$STATE/loaded" "$STATE/tunnel.info" \
      "$STATE/rules.key" "$STATE/rules.sig" "$STATE/up_since" "$STATE/last_state" \
      "$STATE/watchdog.pid" "$STATE/boot.log" "$STATE/nets" "$STATE/last_nets" \
      "$STATE/monitor.pid" "$STATE/events" "$STATE/rules.want" "$STATE/rules.bad" "$STATE/rules.fast" "$STATE/rules.dirty" \
      "$STATE/exempt_uids" "$STATE/heal" "$STATE/dns.want" "$STATE/dns.bad" "$STATE/dns6.want" "$STATE/dns6.bad" \
      "$STATE/live_rx" "$STATE/dead_at" "$STATE/live_probe_at" "$STATE/alive_at" "$STATE/live_paused" "$STATE/pingable" \
      "$STATE/dns_srv" "$STATE/dns_fo_fail" "$STATE/dns_fo_at"
settings_load
if [ -n "$S_ACTIVE" ] && [ "$S_KILLSWITCH" = 1 ]; then
    boot_guard
    wlog INFO "boot: kill switch guard on until tunnel $S_ACTIVE is up"
fi
