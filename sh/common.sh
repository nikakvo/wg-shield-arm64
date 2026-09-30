# WG Shield Arm64 - shared helpers (sourced by every script)
# Works under busybox ash (KSU module scripts) and mksh (ksu.exec / su -c).

MODID=wg-shield
MODDIR="${WGS_MODDIR:-/data/adb/modules/wg-shield}"
DATA="${WGS_DATA:-/data/adb/wg-shield}"
STATE="${WGS_STATE:-/data/adb/wg-shield-state}"
CONF="${WGS_CONFFILE:-/data/adb/wg-shield.conf}"
TUNDIR="$DATA/tunnels"
LOG="$DATA/wg-shield.log"
LOG_MAX=262144

# Absolute paths on purpose: KSU runs module scripts in busybox "standalone"
# mode, where busybox applets (its own `ip` lacks wireguard/suppress_prefixlength)
# would win over the system tools.
IP="${WGS_IP:-/system/bin/ip}"
WG="${WGS_WG:-$MODDIR/system/bin/wg}"
BB="${WGS_BB:-/data/adb/ksu/bin/busybox}"
GETPROP="${WGS_GETPROP:-/system/bin/getprop}"
RT_TABLES="${WGS_RT_TABLES:-/data/misc/net/rt_tables}"

IFACE=wgs0
TABLE=51820
PREFS="5000 5001 5010 5011 5012 5020 5021"
DOWN_AFTER=180          # s without a handshake = tunnel down (WireGuard rejects keys after 180 s)
TICK=10
LINKTYPE="${WGS_LINKTYPE:-wireguard}"   # test harness only

QUIET_ON_SHUTDOWN=0

# ---- small helpers -----------------------------------------------------------
mono_now() { cut -d. -f1 /proc/uptime; }
epoch_now() { date +%s; }

shutting_down() {
    [ -x "$GETPROP" ] || return 1
    [ -n "$("$GETPROP" sys.powerctl 2>/dev/null)" ] && return 0
    [ -n "$("$GETPROP" sys.shutdown.requested 2>/dev/null)" ] && return 0
    return 1
}

wlog() {  # wlog LEVEL message...
    [ "$QUIET_ON_SHUTDOWN" = 1 ] && shutting_down && return 0
    lvl=$1; shift
    [ -d "$DATA" ] || return 0
    if [ -f "$LOG" ] && [ "$(wc -c 2>/dev/null < "$LOG")" -gt "$LOG_MAX" ] 2>/dev/null; then
        mv -f "$LOG" "$LOG.1" 2>/dev/null
    fi
    echo "$(log_ts) [$lvl] $*" >> "$LOG"
}

# before the clock is set (early boot) the date is 1970: show time since boot instead
clock_sane() { [ "$(date +%Y)" -ge 2024 ] 2>/dev/null; }
log_ts() { if clock_sane; then date '+%Y-%m-%d %H:%M:%S'; else echo "boot +$(mono_now)s"; fi; }

tunnel_name_ok() {
    case "$1" in ""|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
    [ "${#1}" -le 40 ]
}

# ---- settings (KEY=value, whitelist, never sourced) ---------------------------
settings_load() {
    S_ACTIVE=""; S_LAST=""; S_KILLSWITCH=1
    [ -f "$CONF" ] || return 0
    while IFS='=' read -r k v; do
        v=$(printf '%s' "$v" | tr -d '\r')
        case "$k" in
            ACTIVE) tunnel_name_ok "$v" && S_ACTIVE=$v ;;
            LAST) tunnel_name_ok "$v" && S_LAST=$v ;;
            KILLSWITCH) case "$v" in 0|1) S_KILLSWITCH=$v ;; esac ;;
        esac
    done 2>/dev/null < "$CONF"
}

settings_save() {
    tmp="$CONF.tmp.$$"
    {
        echo "# WG Shield Arm64 settings - edit with ctl.sh"
        echo "ACTIVE=$S_ACTIVE"
        echo "LAST=$S_LAST"
        echo "KILLSWITCH=$S_KILLSWITCH"
    } > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$CONF"
}

# ---- lock (mkdir + pid, stale takeover) ---------------------------------------
lock_try() {
    mkdir -p "$STATE"
    if mkdir "$STATE/lock" 2>/dev/null; then echo $$ > "$STATE/lock/pid"; return 0; fi
    p=$(cat "$STATE/lock/pid" 2>/dev/null)
    if [ -n "$p" ]; then
        kill -0 "$p" 2>/dev/null && return 1
    else
        # pid not written yet (holder just created it) unless the dir is old
        m=$(stat -c %Y "$STATE/lock" 2>/dev/null || echo 0)
        [ $(( $(epoch_now) - m )) -lt 30 ] && return 1
    fi
    mv "$STATE/lock" "$STATE/lock.stale.$$" 2>/dev/null && rm -rf "$STATE/lock.stale.$$"
    if mkdir "$STATE/lock" 2>/dev/null; then echo $$ > "$STATE/lock/pid"; return 0; fi
    return 1
}

lock_get() {  # lock_get [seconds]
    n=${1:-20}
    while [ "$n" -gt 0 ]; do
        lock_try && return 0
        sleep 1; n=$((n - 1))
    done
    return 1
}

lock_release() {
    [ "$(cat "$STATE/lock/pid" 2>/dev/null)" = "$$" ] && rm -rf "$STATE/lock"
}

# ---- status file (contract for the sibling modules) ----------------------------
# /data/adb/wg-shield-state/status, rewritten atomically, key=value.
status_write() {
    tmp="$STATE/status.tmp.$$"
    {
        echo "state=$ST_STATE"
        echo "reason=$ST_REASON"
        echo "iface=$IFACE"
        echo "table=$TABLE"
        echo "tunnel=$ST_TUNNEL"
        echo "endpoint=$ST_ENDPOINT"
        echo "endpoint_host=$ST_EPHOST"
        echo "ipv6=$ST_IPV6"
        echo "handshake_age=$ST_HSAGE"
        echo "killswitch=$S_KILLSWITCH"
        echo "default_net=$ST_DEF"
        echo "android_vpn=$ST_ANDVPN"
        echo "pause_left=$ST_PAUSELEFT"
        echo "rx=$ST_RX"
        echo "tx=$ST_TX"
        echo "updated=$(epoch_now)"
    } > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$STATE/status"
}

module_desc() {  # keep the manager's description line in sync with the state
    prop="$MODDIR/module.prop"
    [ -w "$prop" ] || return 0
    case "$ST_STATE" in
        up) d="🟢 Protected · $ST_TUNNEL" ;;
        handshaking) d="🟡 Connecting · $ST_TUNNEL" ;;
        down) if [ "$S_KILLSWITCH" = 1 ]; then d="🔴 Tunnel down · internet blocked (kill switch)"; else d="🔴 Tunnel down · direct connection"; fi ;;
        paused) if [ "$ST_REASON" = user ]; then d="⏸️ Paused · direct connection"; else d="⏸️ Paused · another VPN is active"; fi ;;
        error) d="⚠️ Error: $ST_REASON · direct connection" ;;
        *) d="⚪ Off · direct connection" ;;
    esac
    line="description=Always-on kernel WireGuard tunnel without an app, with kill switch. Status: $d"
    grep -qxF "$line" "$prop" 2>/dev/null && return 0
    tmp="$prop.tmp.$$"
    { grep -v '^description=' "$prop"; echo "$line"; } > "$tmp" 2>/dev/null && mv -f "$tmp" "$prop"
}
