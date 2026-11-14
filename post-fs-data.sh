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
# files written with the root manager's umask 0000 before 2.9.1-fork1 (666):
# no write for group / other (600 files stay 600)
chmod go-w "$MODDIR/module.prop" 2>/dev/null
chmod -R go-w "$STATE" "$LOGDIR" 2>/dev/null
rm -rf "$STATE/lock" "$STATE"/import.* "$STATE"/setconf.* "$STATE/test.lock" "$STATE"/testconf.*
# what a process killed in the middle left: temp files (*.tmp.<pid>), rule
# batches, the backup / restore folders, a setconf error
rm -rf "$STATE"/*.tmp.* "$STATE"/rules.batch.* "$STATE"/fast.* "$STATE"/bk.* "$STATE"/bkv.* "$STATE"/restore.* "$STATE/wg.err"
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
