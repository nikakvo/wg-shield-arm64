#!/system/bin/sh
# WG Shield Arm64 - the single CLI (the WebUI will call only this).
# Output: key=value lines. Private keys are never printed.

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
        '  import <zip|conf>   import the WireGuard app export zip (or one .conf)' \
        '  up [name]           turn the tunnel on (last used one when no name)' \
        '  switch <name>       switch to another tunnel (same as up <name>)' \
        '  down                turn the tunnel off - direct connection' \
        '  remove <name>       delete an imported tunnel' \
        '  pause <minutes>     direct connection for a while (1-1440), then back on' \
        '  resume              end a pause now' \
        '  set killswitch 0|1  1 = no internet while the tunnel is down (default)' \
        '  log [lines|clear]   last log lines (default 40) / empty the log' \
        '  poll                everything the WebUI shows (key=value)' \
        '  files               tunnel exports found in Download' \
        '  delfile <name>      delete an export from Download (it holds private keys)' \
        '  exitip              public exit address (one HTTP request)' \
        '  diag                report for troubleshooting (no keys)' \
        '  version'
}

fail() { echo "ok=0"; echo "error=$*"; exit 1; }

[ "$(id -u)" = 0 ] || fail "run as root: su -c 'sh $MODDIR/ctl.sh $*'"
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
            if tun_parse "$(tun_file "$n")"; then
                echo "tunnel=$n endpoint=$T_EP address=$T_ADDR ipv6=$T_V6 active=$a"
            else
                echo "tunnel=$n invalid=1 active=$a error=$(echo "$T_ERR" | tr ' ' '_')"
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
        settings_load
        n=$1
        if [ -z "$n" ]; then
            n=$S_LAST
            [ -n "$n" ] && tun_exists "$n" || { set -- $(tun_names); [ $# -eq 1 ] && n=$1; }
            [ -n "$n" ] || fail "no tunnel given and no last used tunnel - see: ctl.sh list"
        fi
        tun_exists "$n" || fail "no such tunnel: $n"
        tun_parse "$(tun_file "$n")" || fail "tunnel $n is invalid: $T_ERR"
        S_ACTIVE=$n; S_LAST=$n; settings_save
        rm -f "$STATE/pause_until"
        wlog INFO "ctl: up $n"
        wait_up
        print_status
        ;;
    down)
        settings_load; S_ACTIVE=""; settings_save
        rm -f "$STATE/pause_until"
        wlog INFO "ctl: down"
        tick_now; print_status
        ;;
    remove)
        tun_exists "$1" || fail "no such tunnel: $1"
        settings_load
        if [ "$S_ACTIVE" = "$1" ]; then S_ACTIVE=""; fi
        [ "$S_LAST" = "$1" ] && S_LAST=""
        settings_save
        rm -f "$(tun_file "$1")"
        wlog INFO "ctl: tunnel $1 removed"
        tick_now; echo "removed=$1"; print_status
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
        rm -f "$STATE/pause_until"
        wlog INFO "ctl: resume"
        wait_up; print_status
        ;;
    set)
        case "$1" in
            killswitch|KILLSWITCH)
                case "$2" in 0|1) : ;; *) fail "usage: set killswitch 0|1" ;; esac
                settings_load; S_KILLSWITCH=$2; settings_save
                wlog INFO "ctl: kill switch $2"
                tick_now; print_status ;;
            *) fail "unknown setting: $1" ;;
        esac
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
        for n in $(tun_names); do
            if tun_parse "$(tun_file "$n")"; then echo "t=$n|$T_EP|$T_ADDR|1|$T_V6"; else echo "t=$n|-|-|0|0"; fi
        done
        echo "dnscrypt=$(sib_state dnscrypt-proxy-android)"
        echo "dnscrypt_state=$(sed -n 's/^state=//p' "$ADB/dnscrypt-proxy-state/health" 2>/dev/null | head -n1)"
        echo "dnscrypt_ipmode=$(sed -n 's/^IP_MODE=//p' "$ADB/dnscrypt-proxy-android.conf" 2>/dev/null | head -n1)"
        echo "ipset=$(sib_state ipset_arm64)"
        echo "vhs=$(sib_state vpn-hotspot)"
        echo "vhs_state=$(sed -n 's/^state=//p' "$ADB/vpn-hotspot-state/status" 2>/dev/null | head -n1)"
        echo "vhs_code=$(sed -n 's/^versionCode=//p' "$MODULES/vpn-hotspot/module.prop" 2>/dev/null | head -n1)"
        echo "vhs_source=$(sed -n 's/^vpn_source=//p' "$ADB/vpn-hotspot-state/status" 2>/dev/null | head -n1)"
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
        if watchdog_alive; then echo "watchdog running"; else echo "watchdog STOPPED"; fi
        echo; echo "== status"; cat "$STATE/status" 2>/dev/null
        echo; echo "== settings"; grep -v '^#' "$CONF" 2>/dev/null
        echo; echo "== tunnels"; for n in $(tun_names); do if tun_parse "$(tun_file "$n")"; then echo "$n $T_EP $T_ADDR"; else echo "$n INVALID: $T_ERR"; fi; done
        echo; echo "== wg (keys hidden)"; "$WG" show "$IFACE" 2>&1 | grep -viE 'private key|preshared'
        echo; echo "== our rules"; "$IP" rule 2>/dev/null | grep -E '^50[0-9][0-9]:'; "$IP" -6 rule 2>/dev/null | grep -E '^50[0-9][0-9]:' | sed 's/^/v6 /'
        echo; echo "== table $TABLE"; "$IP" route show table "$TABLE" 2>/dev/null
        echo; echo "== netd default / VPN rules"; "$IP" rule 2>/dev/null | grep -E '^(13000|31000):'
        echo; echo "== route checks"; "$IP" route get 1.1.1.1 2>&1 | head -n1
        echo; echo "== siblings"; for m in dnscrypt-proxy-android ipset_arm64 vpn-hotspot; do echo "$m $(sib_state "$m")"; done
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
        ;;
    ""|help|-h|--help) usage ;;
    *) usage; exit 1 ;;
esac
