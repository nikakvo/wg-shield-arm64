# WG Shield Arm64 - shared helpers (sourced by every script)
# Works under busybox ash (KSU module scripts) and mksh (ksu.exec / su -c).

MODID=wg-shield
MODDIR="${WGS_MODDIR:-/data/adb/modules/wg-shield}"
# 1.0-r4: everything in ONE folder (up to r3: /data/adb/wg-shield.conf and
# /data/adb/wg-shield-state/ next to it - see LEGACY_* and layout_migrate):
#   /data/adb/wg-shield/
#     settings.conf   active / last tunnel, kill switch, the other settings
#     tunnels/        imported tunnels with their keys (root only)
#     favorites       favorite tunnel names (2.4+)
#     logs/           wg-shield.log (+ .1)
#     state/          runtime, cleared at boot; state/status = contract for
#                     the sibling modules
DATA="${WGS_DATA:-/data/adb/wg-shield}"
STATE="${WGS_STATE:-$DATA/state}"
CONF="${WGS_CONFFILE:-$DATA/settings.conf}"
TUNDIR="$DATA/tunnels"
FAVS="$DATA/favorites"   # favorite tunnels, one name per line (WebUI star)
# 2.6: one backup of the tunnels in shared storage (kept when the module is
# removed - that is the point): <root>/wg-shield-backup.zip, the same kind of
# zip the WireGuard app exports (+ favorites.txt, backup-info.txt inside).
# A new backup replaces the old one.
BACKUP_ROOT="${WGS_BACKUP_ROOT:-/storage/emulated/0/wg-shield}"
[ -n "$WGS_BACKUP_ROOT" ] || [ -d /storage/emulated/0 ] || BACKUP_ROOT=/sdcard/wg-shield
BKZIP="$BACKUP_ROOT/wg-shield-backup.zip"
LOGDIR="$DATA/logs"
LOG="$LOGDIR/wg-shield.log"
LOG_MAX=262144

WGS_ADB_DIR="${WGS_ADB:-/data/adb}"
LEGACY_STATE="$WGS_ADB_DIR/wg-shield-state"
LEGACY_CONF="$WGS_ADB_DIR/wg-shield.conf"
LEGACY_LOG="$DATA/wg-shield.log"

# Absolute paths on purpose: KSU runs module scripts in busybox "standalone"
# mode, where busybox applets (its own `ip` lacks wireguard/suppress_prefixlength)
# would win over the system tools.
IP="${WGS_IP:-/system/bin/ip}"
WG="${WGS_WG:-$MODDIR/system/bin/wg}"
AWG="${WGS_AWG:-$MODDIR/system/bin/awg}"
# AmneziaWG kernel module (built in or loaded): /sys/module/amneziawg/version
AWG_SYS="${WGS_AWG_SYS:-/sys/module/amneziawg}"
# busybox of the root manager: KernelSU / SukiSU, APatch, Magisk (the first
# one present). nslookup and timeout (host-name endpoints) come only from it.
if [ -n "$WGS_BB" ]; then BB=$WGS_BB
else
    BB="$WGS_ADB_DIR/ksu/bin/busybox"
    for _b in "$WGS_ADB_DIR/ksu/bin/busybox" "$WGS_ADB_DIR/ap/bin/busybox" "$WGS_ADB_DIR/magisk/busybox"; do
        [ -x "$_b" ] && { BB=$_b; break; }
    done
    unset _b
fi
GETPROP="${WGS_GETPROP:-/system/bin/getprop}"
RT_TABLES="${WGS_RT_TABLES:-/data/misc/net/rt_tables}"

IFACE=wgs0
TABLE=51820
PREFS="5000 5001 5010 5011 5012 5013 5014 5020 5021 5022"
DOWN_AFTER=180          # s without a handshake = tunnel down (WireGuard rejects keys after 180 s)
TICK=10
# Tunnel types: "wireguard" (plain configs, e.g. Proton) and "amneziawg"
# (configs with AmneziaWG keys - tun_parse decides). Both use the interface
# wgs0; the link type and the tool (wg / awg) follow the active tunnel.
# WGS_LINKTYPE (test harness only) replaces both link types with a fake one
# (veth) - then no real wg/awg calls are made.
FAKE_LINK=0; [ -n "$WGS_LINKTYPE" ] && FAKE_LINK=1

# link type for a tunnel type
link_type() { if [ "$FAKE_LINK" = 1 ]; then echo "$WGS_LINKTYPE"; else echo "$1"; fi; }
# tool for a tunnel type
wg_tool() { if [ "$1" = amneziawg ]; then echo "$AWG"; else echo "$WG"; fi; }
# kernel has AmneziaWG
awg_kernel_ok() { [ -d "$AWG_SYS" ]; }
awg_kernel_ver() { cat "$AWG_SYS/version" 2>/dev/null; }

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
    [ -d "$LOGDIR" ] || mkdir -p "$LOGDIR" 2>/dev/null
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

# ipv4_ok ADDRESS - four dot-separated numbers 0-255 (no prefix). No leading
# zeros: "010.1.1.1" is 10.1.1.1 for one tool, 8.1.1.1 (octal) for another,
# and iptables refuses it
ipv4_ok() {
    case "$1" in ""|*[!0-9.]*|.*|*.|*..*) return 1 ;; esac
    _o=$IFS; IFS=.; set -f; set -- $1; set +f; IFS=$_o; unset _o
    [ $# = 4 ] || return 1
    for _x in "$@"; do
        case "$_x" in 0?*) unset _x; return 1 ;; esac
        [ "${#_x}" -le 3 ] && [ "$_x" -le 255 ] 2>/dev/null || { unset _x; return 1; }
    done
    unset _x
}

# ---- settings (KEY=value, whitelist, never sourced) ---------------------------
settings_load() {
    S_ACTIVE=""; S_LAST=""; S_KILLSWITCH=1; S_AUTOSWITCH=0; S_NOTIFY=1; S_PROFILE=battery; S_CHECKS=30; S_LANDNS=0
    [ -f "$CONF" ] || return 0
    while IFS='=' read -r k v; do
        v=$(printf '%s' "$v" | tr -d '\r')
        case "$k" in
            ACTIVE) tunnel_name_ok "$v" && S_ACTIVE=$v ;;
            LAST) tunnel_name_ok "$v" && S_LAST=$v ;;
            KILLSWITCH) case "$v" in 0|1) S_KILLSWITCH=$v ;; esac ;;
            AUTOSWITCH) case "$v" in 0|1) S_AUTOSWITCH=$v ;; esac ;;
            NOTIFY) case "$v" in 0|1) S_NOTIFY=$v ;; esac ;;
            PROFILE) case "$v" in battery|always) S_PROFILE=$v ;; esac ;;
            CHECKS) case "$v" in 5|30|off) S_CHECKS=$v ;; esac ;;
            LANDNS) case "$v" in 0|1) S_LANDNS=$v ;; esac ;;
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
        echo "AUTOSWITCH=$S_AUTOSWITCH"
        echo "NOTIFY=$S_NOTIFY"
        echo "PROFILE=$S_PROFILE"
        echo "CHECKS=$S_CHECKS"
        echo "LANDNS=$S_LANDNS"
    } > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$CONF"
}

# ---- lock (mkdir + pid, stale takeover) ---------------------------------------
lock_try() {
    mkdir -p "$STATE"
    if mkdir "$STATE/lock" 2>/dev/null; then echo $$ > "$STATE/lock/pid"; return 0; fi
    i=$(stat -c %i "$STATE/lock" 2>/dev/null)
    p=$(cat "$STATE/lock/pid" 2>/dev/null)
    if [ -n "$p" ]; then
        kill -0 "$p" 2>/dev/null && return 1
    else
        # pid not written yet (holder just created it) unless the dir is old
        m=$(stat -c %Y "$STATE/lock" 2>/dev/null || echo 0)
        [ $(( $(epoch_now) - m )) -lt 30 ] && return 1
    fi
    # the holder is gone. Only one process may take its lock over: mkdir of
    # lock/takeover is atomic. The winner checks that "lock" is still the
    # dead holder's (same directory, same pid) - another process may have
    # taken it over meanwhile and hold a fresh lock there - before it
    # replaces it. A takeover left behind by a process that died in the
    # middle is cleared after 30 s.
    if ! mkdir "$STATE/lock/takeover" 2>/dev/null; then
        m=$(stat -c %Y "$STATE/lock/takeover" 2>/dev/null || epoch_now)
        [ $(( $(epoch_now) - m )) -ge 30 ] && rmdir "$STATE/lock/takeover" 2>/dev/null
        return 1
    fi
    if [ -n "$i" ] && [ "$(stat -c %i "$STATE/lock" 2>/dev/null)" = "$i" ] && [ "$(cat "$STATE/lock/pid" 2>/dev/null)" = "$p" ]; then
        rm -rf "$STATE/lock"
        if mkdir "$STATE/lock" 2>/dev/null; then echo $$ > "$STATE/lock/pid"; return 0; fi
    else
        rmdir "$STATE/lock/takeover" 2>/dev/null
    fi
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
# /data/adb/wg-shield/state/status (r4; /data/adb/wg-shield-state/status
# before), rewritten atomically, key=value.
#
# Compatibility copy at the OLD path, only while a sibling that reads only
# the old path is installed: VPN Hotspot before 1.0-r15 (it routes hotspot
# devices through the tunnel only when it finds this file - without it they
# would be blocked) and DNSCrypt Proxy before 2.1.18-r23 (its VPN row).
# Once both are updated the old folder is removed.
_sib_code() { # <module id> -> versionCode, empty if absent or disabled
    d="${WGS_MODULES:-/data/adb/modules}/$1"
    [ -f "$d/module.prop" ] && [ ! -f "$d/disable" ] && [ ! -f "$d/remove" ] || return 0
    sed -n 's/^versionCode=//p' "$d/module.prop" 2>/dev/null | head -n 1
}
status_compat_needed() {
    c=$(_sib_code vpn-hotspot)
    [ -n "$c" ] && [ "$c" -lt 15 ] 2>/dev/null && return 0
    c=$(_sib_code dnscrypt-proxy-android)
    [ -n "$c" ] && [ "$c" -lt 48 ] 2>/dev/null && return 0
    return 1
}
status_compat() {
    [ "$LEGACY_STATE" != "$STATE" ] || return 0
    if status_compat_needed; then
        mkdir -p "$LEGACY_STATE" 2>/dev/null
        cp -f "$STATE/status" "$LEGACY_STATE/status.tmp.$$" 2>/dev/null &&
            mv -f "$LEGACY_STATE/status.tmp.$$" "$LEGACY_STATE/status"
    elif [ -d "$LEGACY_STATE" ]; then
        rm -rf "$LEGACY_STATE"
    fi
}
status_write() {
    tmp="$STATE/status.tmp.$$"
    # printf, not echo: mksh's echo would interpret a backslash in a value
    {
        printf '%s\n' \
            "state=$ST_STATE" \
            "reason=$ST_REASON" \
            "iface=$IFACE" \
            "table=$TABLE" \
            "type=$ST_TYPE" \
            "tunnel=$ST_TUNNEL" \
            "endpoint=$ST_ENDPOINT" \
            "endpoint_host=$ST_EPHOST" \
            "ipv6=$ST_IPV6" \
            "handshake_age=$ST_HSAGE" \
            "killswitch=$S_KILLSWITCH" \
            "default_net=$ST_DEF" \
            "android_vpn=$ST_ANDVPN" \
            "pause_left=$ST_PAUSELEFT" \
            "rx=$ST_RX" \
            "tx=$ST_TX" \
            "nets=$ST_NETS" \
            "recover=$ST_RECOVER" \
            "recover_from=$ST_RECOVER_FROM" \
            "autoswitch=$S_AUTOSWITCH" \
            "notify=$S_NOTIFY" \
            "profile=$S_PROFILE" \
            "checks=$S_CHECKS" \
            "dns=$ST_DNS" \
            "dns_server=$ST_DNS_SERVER" \
            "updated=$(epoch_now)" \
            "landns=$S_LANDNS" \
            "dns_lan=$ST_DNS_LAN"
    } > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$STATE/status"
    status_compat
}

# ---- r4 layout migration -----------------------------------------------------
# First thing post-fs-data does. The installer only COPIED the settings into
# the new place - the old version keeps running with the old paths until the
# reboot - so the newer copy wins, then the old files go. Idempotent.
_lm_take() { # <old> <new> -> 0 if the old one was taken
    [ -e "$1" ] || return 1
    if [ ! -e "$2" ] || [ "$(stat -c %Y "$1" 2>/dev/null || echo 0)" -gt "$(stat -c %Y "$2" 2>/dev/null || echo 0)" ]; then
        rm -rf "$2" 2>/dev/null
        mv -f "$1" "$2" 2>/dev/null && return 0
    fi
    rm -rf "$1" 2>/dev/null
    return 1
}
layout_migrate() {
    [ -e "$LEGACY_CONF" ] || [ -e "$LEGACY_STATE" ] || [ -e "$LEGACY_LOG" ] || return 0
    mkdir -p "$DATA" "$LOGDIR" "$STATE" 2>/dev/null
    took=""
    _lm_take "$LEGACY_CONF" "$CONF" && took="$took settings"
    chmod 600 "$CONF" 2>/dev/null
    rm -f "$LEGACY_CONF".tmp.* 2>/dev/null
    if [ -f "$LEGACY_LOG" ]; then   # the old log is the history: keep it first
        [ -f "$LEGACY_LOG.1" ] && mv -f "$LEGACY_LOG.1" "$LOG.1" 2>/dev/null
        [ -f "$LOG" ] && cat "$LOG" >> "$LEGACY_LOG" 2>/dev/null
        mv -f "$LEGACY_LOG" "$LOG" 2>/dev/null && took="$took log"
    fi
    [ "$LEGACY_STATE" != "$STATE" ] && rm -rf "$LEGACY_STATE" 2>/dev/null   # runtime only
    wlog INFO "files moved into one folder, $DATA. Taken from the old places:${took:- nothing newer}"
}

module_desc() {  # keep the manager's description line in sync with the state
    prop="$MODDIR/module.prop"
    [ -w "$prop" ] || return 0
    case "$ST_STATE" in
        up) d="🟢 Protected · $ST_TUNNEL$( [ "$ST_TYPE" = amneziawg ] && echo ' (AmneziaWG)')" ;;
        handshaking) if [ "$ST_REASON" = recovering ]; then d="🟡 Recovering ($ST_RECOVER) · $ST_TUNNEL"; else d="🟡 Connecting · $ST_TUNNEL$( [ "$ST_TYPE" = amneziawg ] && echo ' (AmneziaWG)')"; fi ;;
        down) if [ "$S_KILLSWITCH" = 1 ]; then d="🔴 Tunnel down · internet blocked (kill switch)"; else d="🔴 Tunnel down · direct connection"; fi ;;
        paused) if [ "$ST_REASON" = user ]; then d="⏸️ Paused · direct connection"; else d="⏸️ Paused · another VPN is active"; fi ;;
        error) d="⚠️ Error: $ST_REASON · direct connection" ;;
        *) d="⚪ Off · direct connection" ;;
    esac
    line="description=Always-on kernel WireGuard / AmneziaWG tunnel without an app, with kill switch. Status: $d"
    grep -qxF "$line" "$prop" 2>/dev/null && return 0
    tmp="$prop.tmp.$$"
    { grep -v '^description=' "$prop"; echo "$line"; } > "$tmp" 2>/dev/null && mv -f "$tmp" "$prop"
}
