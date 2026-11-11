#!/system/bin/sh
# WG Shield Arm64 - the single CLI (the WebUI will call only this).
# Output: key=value lines. Private keys (and AmneziaWG header protection
# keys) are never printed.

MODDIR="${WGS_MODDIR:-${0%/*}}"
[ -f "$MODDIR/sh/common.sh" ] || MODDIR=/data/adb/modules/wg-shield
. "$MODDIR/sh/common.sh"
. "$MODDIR/sh/tunnels.sh"
. "$MODDIR/sh/net.sh"

usage() {
    printf '%s\n' \
        'Usage: ctl.sh <command>' \
        '  status              current state (key=value)' \
        '  list                imported tunnels' \
        '  import <zip|conf>   import a WireGuard / AmneziaWG export zip (or one .conf)' \
        '  up [name]           turn the tunnel on (last used one when no name)' \
        '  switch <name>       switch to another tunnel (same as up <name>)' \
        '  down                turn the tunnel off - direct connection' \
        '  remove <name>       delete an imported tunnel' \
        '  removeall           delete every imported tunnel (the tunnel turns off)' \
        '  backup              save all tunnels to /storage/emulated/0/wg-shield/wg-shield-backup.zip (replaces the old one)' \
        '  restore             import the tunnels of the backup (same name = replaced)' \
        '  backupinfo          is there a backup, how many tunnels, when' \
        '  delbackup           delete the backup' \
        '  fav add|del <name>  mark / unmark a tunnel as favorite (WebUI star)' \
        '  test <box>          speed test: BG (a country code), others or favorites' \
        '  pause <minutes>     direct connection for a while (1-1440), then back on' \
        '  resume              end a pause now' \
        '  set killswitch 0|1  1 = no internet while the tunnel is down (default)' \
        '  set autoswitch 0|1  1 = when restarts do not help, try other tunnels of the same country' \
        '  set notify 0|1      1 = a notification when the tunnel could not be fixed (default)' \
        '  set profile battery|always  checks only with the screen on (default) / day and night' \
        '  set checks 5|30|off  ping through the tunnel every 5 s / 30 s (default) / never' \
        '  set landns 0|1      1 = while the tunnel is up, DNS to a resolver on the Wi-Fi (the router) goes to the tunnel DNS too' \
        '  restart             restart the watchdog and reconnect the tunnel' \
        '  notifytest          show a test notification' \
        '  log [lines|clear]   last log lines (default 40) / empty the log' \
        '  poll                everything the WebUI shows (key=value)' \
        '  files               tunnel exports found in Download' \
        '  delfile <name>      delete an export from Download (it holds private keys)' \
        '  exitip              public exit address (one HTTP request)' \
        '  diag                report for troubleshooting (no keys)' \
        '  version'
}

fail() { lock_release 2>/dev/null; echo "ok=0"; echo "error=$*"; exit 1; }

# Settings are changed only under the watchdog's lock: a tick can rewrite
# settings.conf itself (the auto-switch saves the tunnel it switched to),
# and a change made between its settings_load and settings_save would be
# lost (a "down" or "set killswitch" undone). fail() releases it.
ctl_lock() { lock_get 20 || fail "busy - try again"; }
# set_locked KEY VALUE - one setting, saved under the lock (kept held: the
# caller ticks and releases)
set_locked() {
    ctl_lock; settings_load
    case "$1" in
        KILLSWITCH) S_KILLSWITCH=$2 ;; AUTOSWITCH) S_AUTOSWITCH=$2 ;; NOTIFY) S_NOTIFY=$2 ;;
        PROFILE) S_PROFILE=$2 ;; CHECKS) S_CHECKS=$2 ;; LANDNS) S_LANDNS=$2 ;;
    esac
    settings_save || fail "cannot write $CONF"
}
tick_locked() { wgs_tick; lock_release; }

[ "$(id -u)" = 0 ] || fail "run as root: su -c '/system/bin/sh $MODDIR/ctl.sh $*'"
mkdir -p "$STATE" "$TUNDIR"; chmod 700 "$DATA" "$TUNDIR" 2>/dev/null


DL="${WGS_DL:-/storage/emulated/0/Download}"
[ -d "$DL" ] || DL=/sdcard/Download
MODULES="${WGS_MODULES:-/data/adb/modules}"
ADB="${WGS_ADB:-/data/adb}"

zip_list() {  # names inside a zip
    if [ -x "$BB" ]; then "$BB" unzip -l "$1" 2>/dev/null; else unzip -l "$1" 2>/dev/null; fi
}

# an export we can import: a zip with .conf files, or a .conf with [Interface]
is_export() {
    case "$1" in
        *.zip|*.ZIP) zip_list "$1" | grep -qiE '\.conf$' ;;
        *.conf|*.CONF) grep -qi '^[[:space:]]*\[interface\]' "$1" 2>/dev/null ;;
        *) return 1 ;;
    esac
}

sib_state() {  # installed / disabled / absent
    d="$MODULES/$1"
    if [ ! -d "$d" ] || [ -f "$d/remove" ]; then echo absent
    elif [ -f "$d/disable" ]; then echo disabled
    else echo on; fi
}

# LAN Cloak Arm64 (same set): read only, shown in the WebUI. It works on
# the Wi-Fi network itself, WG Shield on routing - neither touches the other.
lanc_rows() {
    echo "lancloak=$(sib_state lan-cloak)"
    _lf="$ADB/lan-cloak/state/status"
    _ls=""; _lr=""; _ld=""; _la=""; _lw=""; _lu=""
    if [ -f "$_lf" ]; then
        while IFS='=' read -r _lk _lv; do
            case "$_lk" in
                state) _ls=$_lv ;; reason) _lr=$_lv ;; dhcp) _ld=$_lv ;;
                announce) _la=$_lv ;; wifi) _lw=$_lv ;; updated) _lu=$_lv ;;
            esac
        done 2>/dev/null < "$_lf"
    fi
    echo "lancloak_state=$_ls"
    echo "lancloak_reason=$_lr"
    echo "lancloak_dhcp=$_ld"
    echo "lancloak_announce=$_la"
    echo "lancloak_wifi=$_lw"
    case "$_lu" in
        ''|*[!0-9]*) echo "lancloak_age=" ;;
        *) echo "lancloak_age=$(( $(epoch_now) - _lu ))" ;;
    esac
    unset _lf _ls _lr _ld _la _lw _lu _lk _lv
}

watchdog_alive() {
    p=$(cat "$STATE/watchdog.pid" 2>/dev/null)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && grep -q service.sh "/proc/$p/cmdline" 2>/dev/null
}

_http_get() {  # <host> <path>
    if command -v curl >/dev/null 2>&1; then
        curl -s -m 8 "http://$1$2" 2>/dev/null && return 0
    fi
    if [ -x "$BB" ]; then "$BB" wget -q -T 8 -O - "http://$1$2" 2>/dev/null && return 0; fi
    return 1
}
_json_str() { printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" | head -n 1; }

# poll's tunnel rows, "t=name|endpoint|address|valid|ipv6|type|fav". Parsing
# ~80 files on every poll (every 4 s while the WebUI is open) took seconds, so
# the rows are kept in $STATE/tunrows and made again only when a file in
# tunnels/ changed (name, inode, size, time) or the favorites changed.
tun_rows() {
    _k=$({ stat -c '%n %i %s %Y' "$TUNDIR"/*.conf 2>/dev/null; echo "favorites"; fav_names; } | cksum)
    _c="$STATE/tunrows"
    if [ "$(head -n 1 "$_c" 2>/dev/null)" != "$_k" ]; then
        _fl=$(fav_names)
        {
            echo "$_k"
            for n in $(tun_names); do
                _f=0; printf '%s\n' "$_fl" | grep -qxF "$n" && _f=1
                if tun_parse "$(tun_file "$n")"; then echo "t=$n|$T_EP|$T_ADDR|1|$T_V6|$T_TYPE|$_f"; else echo "t=$n|-|-|0|0|-|$_f"; fi
            done
        } > "$_c.tmp.$$" && mv -f "$_c.tmp.$$" "$_c"
    fi
    tail -n +2 "$_c" 2>/dev/null
}

# route_dev MARK UID - where a socket with this mark and uid goes: the
# interface for 1.1.1.1, else for an IPv6 address (carrier IMS networks are
# IPv6 only), else "blocked"
route_dev() {
    _d=$("$IP" route get 1.1.1.1 mark "$1" uid "$2" 2>/dev/null | head -n1 | sed -n 's/.* dev \([^ ]*\).*/\1/p')
    [ -n "$_d" ] || { _d=$("$IP" -6 route get 2001:4860:4860::8888 mark "$1" uid "$2" 2>/dev/null | head -n1 | sed -n 's/.* dev \([^ ]*\).*/\1/p'); [ -n "$_d" ] && _d="$_d (IPv6)"; }
    echo "${_d:-blocked}"
}

# run one tick now under the lock (the watchdog does the same every 10 s)
tick_now() {
    lock_get 20 || fail "busy - try again"
    wgs_tick
    lock_release
}

print_status() {
    if [ -f "$STATE/status" ]; then echo "ok=1"; cat "$STATE/status"; else fail "no status yet"; fi
}

# after "up": give the first handshake a few seconds
wait_up() {
    n=0
    while [ "$n" -lt 6 ]; do
        tick_now
        case "$(sed -n 's/^state=//p' "$STATE/status" 2>/dev/null)" in handshaking) : ;; *) break ;; esac
        sleep 1; n=$((n + 1))
    done
}

cmd=$1; [ $# -gt 0 ] && shift
case "$cmd" in
    status)
        if lock_try; then wgs_tick; lock_release; fi
        print_status
        ;;
    list)
        settings_load
        c=0
        for n in $(tun_names); do
            c=$((c + 1))
            a=0; [ "$n" = "$S_ACTIVE" ] && a=1
            f=0; fav_has "$n" && f=1
            if tun_parse "$(tun_file "$n")"; then
                echo "tunnel=$n endpoint=$T_EP address=$T_ADDR ipv6=$T_V6 type=$T_TYPE active=$a fav=$f"
            else
                echo "tunnel=$n invalid=1 active=$a fav=$f error=$(echo "$T_ERR" | tr ' ' '_')"
            fi
        done
        echo "ok=1"; echo "count=$c"; echo "active=$S_ACTIVE"; echo "last=$S_LAST"
        ;;
    import)
        [ -n "$1" ] || fail "usage: import <zip|conf>"
        src=$1; case "$src" in */*) : ;; *) src="$DL/$src" ;; esac
        lock_get 20 || fail "busy - try again"
        tun_import "$src"; rc=$?
        lock_release
        [ "$rc" = 0 ] && echo "note=delete the export from shared storage - it contains private keys"
        exit "$rc"
        ;;
    up|switch)
        ctl_lock
        settings_load
        n=$1
        if [ -z "$n" ]; then
            n=$S_LAST
            [ -n "$n" ] && tun_exists "$n" || { set -- $(tun_names); [ $# -eq 1 ] && n=$1; }
            [ -n "$n" ] || fail "no tunnel given and no last used tunnel - see: ctl.sh list"
        fi
        tun_exists "$n" || fail "no such tunnel: $n"
        tun_parse "$(tun_file "$n")" || fail "tunnel $n is invalid: $T_ERR"
        if [ "$T_TYPE" = amneziawg ] && [ "$FAKE_LINK" = 0 ] && ! awg_kernel_ok; then
            fail "$n is an AmneziaWG tunnel and this kernel has no AmneziaWG (CONFIG_AMNEZIAWG) - WireGuard tunnels still work"
        fi
        S_ACTIVE=$n; S_LAST=$n; settings_save || fail "cannot write $CONF"
        rm -f "$STATE/pause_until" "$STATE/heal"
        wlog INFO "ctl: up $n"
        lock_release
        wait_up
        print_status
        ;;
    down)
        ctl_lock
        settings_load; S_ACTIVE=""; settings_save || fail "cannot write $CONF"
        rm -f "$STATE/pause_until" "$STATE/heal"
        wlog INFO "ctl: down"
        tick_locked; print_status
        ;;
    remove)
        tun_exists "$1" || fail "no such tunnel: $1"
        ctl_lock
        settings_load
        if [ "$S_ACTIVE" = "$1" ]; then S_ACTIVE=""; fi
        [ "$S_LAST" = "$1" ] && S_LAST=""
        settings_save || fail "cannot write $CONF"
        rm -f "$(tun_file "$1")"
        fav_has "$1" && fav_del "$1"
        wlog INFO "ctl: tunnel $1 removed"
        tick_locked; echo "removed=$1"; print_status
        ;;
    removeall)
        test_running && fail "a speed test is running - wait until it ends"
        ra_n=0
        for f in "$TUNDIR"/*.conf; do [ -f "$f" ] && ra_n=$((ra_n + 1)); done
        ctl_lock
        settings_load; S_ACTIVE=""; S_LAST=""; settings_save || fail "cannot write $CONF"
        rm -f "$STATE/pause_until" "$STATE/heal"
        for f in "$TUNDIR"/*.conf; do [ -f "$f" ] && rm -f "$f"; done
        rm -f "$FAVS"
        ra_left=0
        for f in "$TUNDIR"/*.conf; do [ -f "$f" ] && ra_left=$((ra_left + 1)); done
        [ "$ra_left" = 0 ] || fail "$ra_left tunnel(s) could not be deleted"
        wlog INFO "ctl: all tunnels removed ($ra_n)"
        tick_locked; echo "removed=$ra_n"; print_status
        ;;
    backup)
        lock_get 20 || fail "busy - try again"
        out=$(bk_make); rc=$?
        lock_release
        [ "$rc" = 0 ] || fail "$(echo "$out" | sed -n 's/^error=//p')"
        wlog INFO "ctl: backup of $(echo "$out" | sed -n 's/^backed_up=//p') tunnels to $BKZIP"
        echo "ok=1"; echo "$out"; echo "file=$BKZIP"; echo "favorites=$(fav_names | grep -c .)"
        echo "note=the backup holds your private keys - shared storage is readable by apps with file access"
        ;;
    restore)
        lock_get 20 || fail "busy - try again"
        out=$(bk_restore); rc=$?
        lock_release
        err=$(echo "$out" | sed -n 's/^error=//p')
        [ -z "$err" ] || fail "$err"
        wlog INFO "ctl: restore from $BKZIP - $(echo "$out" | sed -n 's/^imported=//p') imported, $(echo "$out" | sed -n 's/^skipped=//p') skipped"
        if [ "$rc" = 0 ]; then echo "ok=1"; else echo "ok=0"; echo "error=nothing imported (see Log)"; fi
        echo "$out"
        exit "$rc"
        ;;
    backupinfo)
        bk_fix
        n=$(bk_count)
        echo "ok=1"; echo "file=$BKZIP"
        if [ "$n" -gt 0 ]; then
            c=$(bk_created); [ -n "$c" ] || c=$(stat -c %Y "$BKZIP" 2>/dev/null)
            echo "exists=1"; echo "tunnels=$n"; echo "created=$c"; echo "favorites=$(bk_favs)"
            echo "size=$(stat -c %s "$BKZIP" 2>/dev/null)"
        else
            echo "exists=0"
        fi
        ;;
    delbackup)
        bk_fix
        [ -f "$BKZIP" ] || fail "no backup"
        rm -f "$BKZIP" || fail "cannot delete $BKZIP"
        rm -rf "$BACKUP_ROOT/backup"
        rmdir "$BACKUP_ROOT" 2>/dev/null
        wlog INFO "ctl: backup deleted"
        echo "ok=1"; echo "deleted=1"
        ;;
    fav)
        case "$1" in add|del) : ;; *) fail "usage: fav add|del <name>" ;; esac
        tunnel_name_ok "$2" || fail "not a valid tunnel name: $2"
        if [ "$1" = add ]; then
            tun_exists "$2" || fail "no such tunnel: $2"
            fav_has "$2" || fav_add "$2" || fail "cannot write $FAVS"
            f=1
        else
            ! fav_has "$2" || fav_del "$2" || fail "cannot write $FAVS"
            f=0
        fi
        echo "ok=1"; echo "tunnel=$2"; echo "fav=$f"
        ;;
    test)
        case "$1" in
            [A-Z][A-Z]|others|favorites) : ;;
            *) fail "usage: test <country code like BG | others | favorites>" ;;
        esac
        test_lock_get || fail "a speed test is already running"
        trap 'test_cleanup; test_lock_release' EXIT
        trap 'exit 1' INT TERM HUP
        test_run "$1"; rc=$?
        exit "$rc"
        ;;
    pause)
        case "$1" in ""|*[!0-9]*) fail "usage: pause <minutes 1-1440>" ;; esac
        [ "$1" -ge 1 ] && [ "$1" -le 1440 ] || fail "minutes must be 1-1440"
        settings_load; [ -n "$S_ACTIVE" ] || fail "tunnel is off - nothing to pause"
        echo $(( $(mono_now) + $1 * 60 )) > "$STATE/pause_until"
        wlog INFO "ctl: pause $1 min"
        tick_now; print_status
        ;;
    resume)
        rm -f "$STATE/pause_until" "$STATE/heal"
        wlog INFO "ctl: resume"
        wait_up; print_status
        ;;
    set)
        case "$1" in
            killswitch|KILLSWITCH)
                case "$2" in 0|1) : ;; *) fail "usage: set killswitch 0|1" ;; esac
                set_locked KILLSWITCH "$2"
                wlog INFO "ctl: kill switch $2"
                tick_locked; print_status ;;
            autoswitch|AUTOSWITCH)
                case "$2" in 0|1) : ;; *) fail "usage: set autoswitch 0|1" ;; esac
                set_locked AUTOSWITCH "$2"
                wlog INFO "ctl: auto-switch $2"
                tick_locked; print_status ;;
            profile|PROFILE)
                case "$2" in battery|always) : ;; *) fail "usage: set profile battery|always" ;; esac
                set_locked PROFILE "$2"
                wlog INFO "ctl: profile $2"
                tick_locked; print_status ;;
            checks|CHECKS)
                case "$2" in 5|30|off) : ;; *) fail "usage: set checks 5|30|off" ;; esac
                set_locked CHECKS "$2"
                if [ "$2" = off ]; then wlog INFO "ctl: checks off - only the handshake rule (180 s)"
                else wlog INFO "ctl: checks every $2 s"; fi
                rm -f "$STATE/live_probe_at"    # a new interval starts with a check
                # off: an old "no answer" must not start a recovery now
                [ "$2" = off ] && rm -f "$STATE/dead_at" "$STATE/alive_at"
                tick_locked; print_status ;;
            notify|NOTIFY)
                case "$2" in 0|1) : ;; *) fail "usage: set notify 0|1" ;; esac
                set_locked NOTIFY "$2"
                wlog INFO "ctl: notifications $2"
                tick_locked; print_status ;;
            landns|LANDNS)
                case "$2" in 0|1) : ;; *) fail "usage: set landns 0|1" ;; esac
                set_locked LANDNS "$2"
                wlog INFO "ctl: LAN DNS through the tunnel $2"
                tick_locked; print_status ;;
            *) fail "unknown setting: $1" ;;
        esac
        ;;
    restart)
        # 1. stop the watchdog (its TERM trap also stops its ip monitor)
        p=$(cat "$STATE/watchdog.pid" 2>/dev/null)
        if watchdog_alive; then
            kill "$p" 2>/dev/null
            n=0; while kill -0 "$p" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1 2>/dev/null || sleep 1; n=$((n + 1)); done
            kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
        fi
        m=$(cat "$STATE/monitor.pid" 2>/dev/null)
        [ -n "$m" ] && grep -q monitor "/proc/$m/cmdline" 2>/dev/null && kill "$m" 2>/dev/null
        rm -f "$STATE/watchdog.pid" "$STATE/monitor.pid" "$STATE/events"
        # 2. a fresh tunnel interface (new port, new handshake) and a fresh
        #    recovery; the kill switch holds meanwhile (table 51820's
        #    unreachable route), a pause or "off" is kept
        lock_get 20 || fail "busy - try again"
        wlog INFO "ctl: restart"
        "$IP" link del "$IFACE" 2>/dev/null
        rm -f "$STATE/loaded" "$STATE/heal" "$STATE/rules.key" "$STATE/resolved_at" \
              "$STATE/live_rx" "$STATE/dead_at" "$STATE/live_probe_at" "$STATE/alive_at" "$STATE/live_paused"
        lock_release
        # 3. a new watchdog, in its own session: it keeps running after the
        #    WebUI / terminal that started it is gone
        if command -v setsid >/dev/null 2>&1; then SS=setsid; elif [ -x "$BB" ]; then SS="$BB setsid"; else SS=""; fi
        $SS ${WGS_SH:-/system/bin/sh} "$MODDIR/service.sh" </dev/null >/dev/null 2>&1 &
        n=0; while ! watchdog_alive && [ "$n" -lt 30 ]; do sleep 0.1 2>/dev/null || sleep 1; n=$((n + 1)); done
        watchdog_alive || fail "the watchdog did not start - reboot the phone"
        settings_load
        [ -n "$S_ACTIVE" ] && [ ! -f "$STATE/pause_until" ] && wait_up
        echo "restarted=1"
        print_status
        ;;
    poll)
        if lock_try; then wgs_tick; lock_release; fi
        settings_load
        echo "ok=1"
        cat "$STATE/status" 2>/dev/null
        echo "active=$S_ACTIVE"
        echo "last=$S_LAST"
        echo "version=$(sed -n 's/^version=//p' "$MODDIR/module.prop")"
        if watchdog_alive; then echo "watchdog=running"; else echo "watchdog=stopped"; fi
        t=$(cat "$STATE/tick" 2>/dev/null); [ -n "$t" ] && echo "tick_age=$(( $(epoch_now) - t ))"
        tun_rows
        echo "awg_kernel=$(awg_kernel_ver)"
        echo "dnscrypt=$(sib_state dnscrypt-proxy-android)"
        # DNSCrypt Proxy r22+ keeps everything in /data/adb/dnscrypt-proxy/, older versions at the top of /data/adb
        h="$ADB/dnscrypt-proxy/state/health"; [ -f "$h" ] || h="$ADB/dnscrypt-proxy-state/health"
        echo "dnscrypt_state=$(sed -n 's/^state=//p' "$h" 2>/dev/null | head -n1)"
        echo "dnscrypt_ipmode=$(sed -n 's/^IP_MODE=//p' "$(dnsc_conf)" 2>/dev/null | tail -n1)"
        echo "ipset=$(sib_state ipset_arm64)"
        echo "vhs=$(sib_state vpn-hotspot)"
        # VPN Hotspot r15+ keeps its status in /data/adb/vpn-hotspot/state/
        vs="$ADB/vpn-hotspot/state/status"; [ -f "$vs" ] || vs="$ADB/vpn-hotspot-state/status"
        echo "vhs_state=$(sed -n 's/^state=//p' "$vs" 2>/dev/null | head -n1)"
        echo "vhs_code=$(sed -n 's/^versionCode=//p' "$MODULES/vpn-hotspot/module.prop" 2>/dev/null | head -n1)"
        echo "vhs_source=$(sed -n 's/^vpn_source=//p' "$vs" 2>/dev/null | head -n1)"
        lanc_rows
        test_rows
        if test_running; then echo "test_run=$(cat "$TEST_PROG" 2>/dev/null)"; fi
        ;;
    notifytest)
        settings_load; S_NOTIFY=1
        notify "Test notification - this is how WG Shield tells you when a tunnel could not be fixed."
        if tail -n 1 "$LOG" 2>/dev/null | grep -q 'notification: Test'; then echo "ok=1"; else fail "the notification could not be posted (see Log)"; fi
        ;;
    files)
        echo "ok=1"
        echo "dir=$DL"
        for f in "$DL"/*.zip "$DL"/*.ZIP "$DL"/*.conf "$DL"/*.CONF; do
            [ -f "$f" ] || continue
            is_export "$f" || continue
            set -- $(stat -c '%s %Y' "$f" 2>/dev/null)
            n=0; case "$f" in *.zip|*.ZIP) n=$(zip_list "$f" | grep -ciE '\.conf$') ;; *) n=1 ;; esac
            echo "$2|file=${f##*/}|$1|$2|$n"
        done | sort -rn | cut -d'|' -f2-
        ;;
    delfile)
        case "$1" in ""|*/*|.*) fail "usage: delfile <file name in Download>" ;; esac
        f="$DL/$1"
        [ -f "$f" ] || fail "not found: $1"
        is_export "$f" || fail "not a tunnel export: $1"
        rm -f "$f" || fail "cannot delete $1"
        wlog INFO "ctl: export $1 deleted from Download"
        echo "ok=1"; echo "deleted=$1"
        ;;
    exitip)
        via=""; [ "$(sed -n 's/^state=//p' "$STATE/status" 2>/dev/null)" = up ] && via=$IFACE
        j=$(_http_get ip-api.com '/json/?fields=status,country,countryCode,city,isp,query')
        ip=$(_json_str "$j" query)
        if [ -n "$ip" ]; then
            echo "ip=$ip"; echo "country=$(_json_str "$j" country)"; echo "city=$(_json_str "$j" city)"; echo "isp=$(_json_str "$j" isp)"
        else
            j=$(_http_get ipinfo.io /json); ip=$(_json_str "$j" ip)
            [ -n "$ip" ] || fail "no answer from ip-api.com or ipinfo.io"
            echo "ip=$ip"; echo "country=$(_json_str "$j" country)"; echo "city=$(_json_str "$j" city)"; echo "isp=$(_json_str "$j" org)"
        fi
        echo "via=$via"; echo "ok=1"
        ;;
    diag)
        if lock_try; then wgs_tick; lock_release; fi
        echo "== WG Shield report $(date '+%Y-%m-%d %H:%M:%S')"
        sed -n 's/^version=/version /p' "$MODDIR/module.prop"
        echo "kernel $(uname -r)"; echo "wg $("$WG" --version 2>/dev/null | awk '{ print $2; exit }')"
        echo "awg $("$AWG" --version 2>/dev/null | awk '{ print $2; exit }')"
        if awg_kernel_ok; then echo "amneziawg kernel $(awg_kernel_ver)"; else echo "amneziawg kernel: no"; fi
        if watchdog_alive; then echo "watchdog running"; else echo "watchdog STOPPED"; fi
        echo; echo "== status"; cat "$STATE/status" 2>/dev/null
        echo; echo "== settings"; grep -v '^#' "$CONF" 2>/dev/null
        [ -f "$STATE/heal" ] && { echo; echo "== recovery"; cat "$STATE/heal"; }
        echo; echo "== favorites"; fav_names
        echo; echo "== backup"; if [ "$(bk_count)" -gt 0 ]; then echo "$BKZIP: $(bk_count) tunnels, created $(bk_created)"; else echo "none ($BKZIP)"; fi
        echo; echo "== speed test (address|handshake ms|ping ms|result|epoch|tunnels)"; cat "$TEST_FILE" 2>/dev/null
        echo; echo "== tunnels"; for n in $(tun_names); do if tun_parse "$(tun_file "$n")"; then echo "$n $T_EP $T_ADDR $T_TYPE"; else echo "$n INVALID: $T_ERR"; fi; done
        k=$(iface_kind)
        if [ "$k" = amneziawg ]; then
            echo; echo "== awg (keys hidden)"; "$AWG" show "$IFACE" 2>&1 | grep -viE 'private key|preshared|protection key'
        else
            echo; echo "== wg (keys hidden)"; "$WG" show "$IFACE" 2>&1 | grep -viE 'private key|preshared'
        fi
        echo; echo "== our rules"; "$IP" rule 2>/dev/null | grep -E '^50[0-9][0-9]:'; "$IP" -6 rule 2>/dev/null | grep -E '^50[0-9][0-9]:' | sed 's/^/v6 /'
        echo; echo "== table $TABLE"; "$IP" route show table "$TABLE" 2>/dev/null
        echo; echo "== DNS (nat OUTPUT port 53 and our chains)"; _nat_dump "$IPTS" "$IPT" | grep -E 'wgs_dns|--dport 53'
        [ -f "$STATE/dns6.want" ] && _nat_dump "$IPTS6" "$IPT6" | grep -E 'wgs_dns|--dport 53' | sed 's/^/v6 /'
        echo; echo "== rules wanted ($(grep -c . "$STATE/rules.want" 2>/dev/null))"; sed 's/ rule add pref / /' "$STATE/rules.want" 2>/dev/null
        echo "key $(cat "$STATE/rules.key" 2>/dev/null)"
        echo "kept on their own network (uids): $(cat "$STATE/exempt_uids" 2>/dev/null || echo "$NETSTACK_UID (package manager not asked yet)")"
        echo; echo "== networks (netId interface class table)"; tail -n +3 "$STATE/nets" 2>/dev/null
        if mon_pid=$(cat "$STATE/monitor.pid" 2>/dev/null) && [ -n "$mon_pid" ] && kill -0 "$mon_pid" 2>/dev/null; then
            echo "network change watch: running (pid $mon_pid)"; else echo "network change watch: not running"; fi
        echo; echo "== netd default / VPN rules"; "$IP" rule 2>/dev/null | grep -E '^(13000|31000):'
        echo; echo "== route checks (1.1.1.1)"; "$IP" route get 1.1.1.1 2>&1 | head -n1
        # a socket bound to each network (its explicit mark), from an app and
        # from Android's own network check (NetworkStack, uid 1073)
        detect_net
        _oifs=$IFS; IFS='
'
        for l in $NETS_ALL; do
            IFS=' '; set -- $l; IFS='
'
            mk=$(printf '0x%x' $(( 0x10000 | $2 | ($3 << 18) )))
            ra=$(route_dev "$mk" 10000); rn=$(route_dev "$mk" "$NETSTACK_UID")
            # a carrier network without any route (e.g. an emergency / IMS one
            # that is not in use) is not blocked by us: nothing can go there
            if [ "$3" -ge 2 ]; then
                [ "$ra" = blocked ] && ra="no route (carrier network, not used now)"
                [ "$rn" = blocked ] && rn="no route"
            fi
            echo "bound to $4 (netId $2): app -> $ra, android check -> $rn"
        done
        IFS=$_oifs
        echo; echo "== siblings"; for m in dnscrypt-proxy-android ipset_arm64 vpn-hotspot lan-cloak; do echo "$m $(sib_state "$m")"; done
        echo; echo "== log (last 40)"; tail -n 40 "$LOG" 2>/dev/null
        ;;
    log)
        if [ "$1" = clear ]; then
            : > "$LOG" 2>/dev/null || fail "cannot write $LOG"
            rm -f "$LOG.1"; wlog INFO "log cleared"; echo "ok=1"; exit 0
        fi
        n=${1:-40}; case "$n" in *[!0-9]*) n=40 ;; esac
        tail -n "$n" "$LOG" 2>/dev/null
        ;;
    version)
        echo "ok=1"
        sed -n 's/^version=/version=/p; s/^versionCode=/versionCode=/p' "$MODDIR/module.prop"
        echo "wg=$("$WG" --version 2>/dev/null | awk '{ print $2; exit }')"
        echo "awg=$("$AWG" --version 2>/dev/null | awk '{ print $2; exit }')"
        echo "awg_kernel=$(awg_kernel_ver)"
        ;;
    ""|help|-h|--help) usage ;;
    *) usage; exit 1 ;;
esac
