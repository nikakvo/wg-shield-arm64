# WG Shield Arm64 - self-healing (sourced after net.sh)
#
# Profile (settings PROFILE): "battery" (default) checks only while the screen
# is on - with the screen off nothing is pinged (no wake-ups, no data), the
# first check runs as soon as the screen comes on; "always" checks day and
# night (hotspot devices, background apps). A recovery in progress is always
# followed, screen or not. WireGuard's 180 s rule works in both.
#
# How often (settings CHECKS): 5 = every 5 s, 30 = every 30 s (default),
# off = never - then only WireGuard's 180 s handshake rule finds a dead
# tunnel (no requests at all; the self-healing still runs, just later).
#
# Liveness: every CHECKS s the watchdog pings through the tunnel
# (1.1.1.1, then 9.9.9.9, ~3 s each; bound to wgs0). The rx counter is NOT
# used: incoming traffic does not prove the way out works (with the way out
# blocked the server kept sending for minutes). No answer twice = the tunnel
# carries nothing
# ($STATE/dead_at), the state becomes down (reason no_answer) at once instead
# of after WireGuard's 180 s without a handshake (still the backstop).
#
# When the active tunnel is down while the phone has a network, the watchdog
# tries to bring it back by itself:
#   1. restart the tunnel (new interface = new handshake from a new port;
#      a host-name endpoint is looked up again) - twice
#   2. only with AUTOSWITCH=1: switch to another imported tunnel - first the
#      same country (name like wg-BG-14 -> other *-BG-* tunnels), then any
#      other tunnel; never one on a server address that already failed;
#      inside each group by the last speed test; at most HEAL_MAX_SWITCH
#      tunnels
#   3. nothing helped: back to the tunnel the user picked, state stays down
#      (kill switch as set) and ONE notification says what was tried
# Each step gets HEAL_WAIT seconds to carry traffic again (handshake + an
# answer through the tunnel). The kill switch holds the
# whole time (table 51820's unreachable route stays while wgs0 is recreated).
# A restart that fixed it is only logged; a switch or a failure is notified.
# The attempt is forgotten when the tunnel answers, the user changes the
# tunnel / pauses / turns it off, or the network changes.
#
# State: $STATE/heal (key=value): orig cur step at tried done notified def

HEAL_WAIT=${WGS_HEAL_WAIT:-10}
HEAL_RESTARTS=2
HEAL_MAX_SWITCH=5
SU="${WGS_SU:-/system/bin/su}"
CMD="${WGS_CMD:-/system/bin/cmd}"
PING="${WGS_PING:-/system/bin/ping}"
PROBE_TARGETS="${WGS_PROBE:-1.1.1.1 9.9.9.9}"
LIVE_EVERY=${WGS_LIVE_EVERY:-5}

# ---- liveness -------------------------------------------------------------------
# one ping through the tunnel (bound to wgs0, so it never goes around it):
# up to 6 tries in 3 s per target, the first answer is enough
probe_once() {
    for _p in $PROBE_TARGETS; do
        "$PING" -c 1 -i 0.5 -w 3 -I "$IFACE" "$_p" >/dev/null 2>&1 && { unset _p; return 0; }
    done
    unset _p; return 1
}
# time since boot in 1/100 s (alive_at / dead_at: a second is too coarse)
mono_cs() { cut -d' ' -f1 /proc/uptime | tr -d .; }
# screen on? debug.tracing.screen_state (Android's power service: 1 off,
# 2 on), else dumpsys power; unknown = on (check rather than miss a failure)
screen_on() {
    case "$("$GETPROP" debug.tracing.screen_state 2>/dev/null)" in 1) return 1 ;; 2) return 0 ;; esac
    case "$("$DUMPSYS" power 2>/dev/null | grep -m1 -o 'mWakefulness=[A-Za-z]*')" in
        *=Awake) return 0 ;; *=*) return 1 ;;
    esac
    return 0
}
# tunnels that answered our ping at least once since boot: only for them a
# missing answer means "dead" (a server that drops ICMP must not be
# restarted forever; for it the handshake rule alone decides)
# (Checks off: nothing is pinged, so no tunnel counts - the handshake decides)
tun_pingable() { [ "$S_CHECKS" != off ] && grep -qxF "$1" "$STATE/pingable" 2>/dev/null; }
heal_active() { [ -f "$STATE/heal" ] && ! grep -q '^done=1' "$STATE/heal" 2>/dev/null; }

live_reset() { rm -f "$STATE/live_rx" "$STATE/dead_at" "$STATE/live_probe_at" "$STATE/alive_at"; }

# live_check - run by the watchdog between ticks, without the lock (it only
# writes its own files). 1 = something changed, tick now.
live_check() {
    [ -f "$STATE/status" ] || return 0
    # Checks off: no pings at all - only WireGuard's handshake rule (180 s)
    if [ "$S_CHECKS" = off ]; then
        rm -f "$STATE/live_paused"
        if [ -f "$STATE/dead_at" ]; then live_reset; return 1; fi   # forget "no answer"
        live_reset; return 0
    fi
    _st=""; _ks=""; _tn=""
    while IFS='=' read -r _k _v; do
        case "$_k" in state) _st=$_v ;; killswitch) _ks=$_v ;; tunnel) _tn=$_v ;; esac
    done 2>/dev/null < "$STATE/status"
    case "$_st" in
        up) : ;;
        down|handshaking) [ "$_ks" = 1 ] || return 0 ;;   # without capture a ping proves nothing
        *) live_reset; return 0 ;;
    esac
    # Battery profile: nothing while the screen is off (unless a recovery runs)
    if [ "$S_PROFILE" != always ] && ! heal_active && ! screen_on; then
        if [ ! -f "$STATE/live_paused" ]; then
            touch "$STATE/live_paused"
            wlog INFO "screen off - checks paused (Battery profile)"
        fi
        return 0
    fi
    if [ -f "$STATE/live_paused" ]; then
        rm -f "$STATE/live_paused" "$STATE/live_probe_at"
        wlog INFO "screen on - checking the tunnel again"
    fi
    # Only an answer to our own ping counts: traffic coming IN proves nothing
    # (measured: with the way out blocked the server still sends for minutes).
    [ -e "${WGS_SYSNET:-/sys/class/net}/$IFACE" ] || return 0
    _now=$(mono_now)
    # how often: CHECKS 5 = at every call (the watchdog calls every 5 s),
    # 30 = every 30 s; while down every 15 s (5) / 30 s (30, 15 during a
    # recovery) is enough;
    # a recovery in progress is followed at every call (each step has only
    # HEAL_WAIT s to answer). A network change or the screen coming on
    # removes live_probe_at = check at once.
    _iv=0
    if [ "$_st" != up ]; then
        _iv=15; [ "$S_CHECKS" = 30 ] && ! heal_active && _iv=30
    elif [ "$S_CHECKS" = 30 ] && ! heal_active; then
        _iv=29     # (the calls come every ~5.1 s: 29 keeps it at 30, not 35)
    fi
    if [ "$_iv" -gt 0 ]; then
        _last=$(cat "$STATE/live_probe_at" 2>/dev/null || echo 0)
        [ $(( _now - _last )) -ge "$_iv" ] || return 0
    fi
    echo "$_now" > "$STATE/live_probe_at"
    if probe_once || { [ "$_st" = up ] && tun_pingable "$_tn" && probe_once; }; then
        mono_cs > "$STATE/alive_at"
        tun_pingable "$_tn" || echo "$_tn" >> "$STATE/pingable"
        if [ -f "$STATE/dead_at" ]; then rm -f "$STATE/dead_at"; return 1; fi
        return 0
    fi
    [ "$_st" = up ] || return 0
    tun_pingable "$_tn" || return 0   # never answered a ping: cannot tell
    _a=$(cat "$STATE/alive_at" 2>/dev/null || echo -1)
    _d=$(cat "$STATE/dead_at" 2>/dev/null || echo -1)
    if [ "$_d" -le "$_a" ] 2>/dev/null; then
        mono_cs > "$STATE/dead_at"
        wlog WARN "$_tn: no answer through the tunnel (ping $(echo $PROBE_TARGETS | sed 's/ / and /g'))"
    fi
    return 1
}

# live_dead HS - 0 when the last sign of the tunnel is "no answer" (newer than
# the last answer). With the kill switch off nothing is pinged while it is
# down, so a newer handshake counts as a sign of life too.
live_dead() {
    _d=$(cat "$STATE/dead_at" 2>/dev/null); [ -n "$_d" ] || return 1
    _a=$(cat "$STATE/alive_at" 2>/dev/null || echo -1)
    [ "$_d" -gt "$_a" ] 2>/dev/null || return 1
    if [ "$S_KILLSWITCH" = 0 ] && [ "$1" -gt 0 ] 2>/dev/null; then
        [ $(( ($1 - $(epoch_now) + $(mono_now)) * 100 )) -gt "$_d" ] && return 1
    fi
    return 0
}

heal_load() {
    H_ORIG=""; H_CUR=""; H_STEP=0; H_AT=0; H_TRIED=""; H_DONE=0; H_NOTIFIED=0; H_DEF=""
    [ -f "$STATE/heal" ] || return 0
    while IFS='=' read -r _hk _hv; do
        case "$_hk" in
            orig) tunnel_name_ok "$_hv" && H_ORIG=$_hv ;;
            cur) tunnel_name_ok "$_hv" && H_CUR=$_hv ;;
            step) case "$_hv" in ''|*[!0-9]*) : ;; *) H_STEP=$_hv ;; esac ;;
            at) case "$_hv" in ''|*[!0-9]*) : ;; *) H_AT=$_hv ;; esac ;;
            tried) H_TRIED=$_hv ;;
            done) [ "$_hv" = 1 ] && H_DONE=1 ;;
            notified) [ "$_hv" = 1 ] && H_NOTIFIED=1 ;;
            def) H_DEF=$_hv ;;
        esac
    done 2>/dev/null < "$STATE/heal"
    unset _hk _hv
}

heal_save() {
    {
        echo "orig=$H_ORIG"; echo "cur=$H_CUR"; echo "step=$H_STEP"; echo "at=$H_AT"
        echo "tried=$H_TRIED"; echo "done=$H_DONE"; echo "notified=$H_NOTIFIED"; echo "def=$H_DEF"
    } > "$STATE/heal.tmp.$$" && mv -f "$STATE/heal.tmp.$$" "$STATE/heal"
}

heal_clear() { rm -f "$STATE/heal"; H_ORIG=""; H_CUR=""; H_STEP=0; H_DONE=0; H_NOTIFIED=0; H_TRIED=""; }

# country code of a tunnel name: the first part of exactly two capital
# letters (wg-BG-14 -> BG, wg-NL-FREE-3 -> NL), empty when there is none
tun_country() {
    echo "$1" | awk -F'[-_.]' '{ for (i = 1; i <= NF; i++) if ($i ~ /^[A-Z][A-Z]$/) { print $i; exit } }'
}

# endpoint (host or address, without the port) of a tunnel, empty if invalid
tun_ep_host() { ( tun_parse "$(tun_file "$1")" >/dev/null 2>&1 && echo "${T_EP%:*}" ); }

# next tunnel to try, empty = none left. Runs in a subshell (tun_parse and
# tun_names use global variables).
# Order (2.4): a server address that already failed in this attempt (the
# picked tunnel's and every tried one's) is never tried again - tunnels on
# one address (Proton: one machine, several exit addresses) fail together.
# Same country first, then every other tunnel; inside each group by the last
# speed test (fastest first, untested next, tested-and-failed last), then by
# name.
heal_pick() {
    (
        _cc=$(tun_country "$H_ORIG")
        _bad=" $(tun_ep_host "$H_ORIG") "
        for _t in $H_TRIED; do _bad="$_bad$(tun_ep_host "$_t") "; done
        _i=0
        for _hn in $(tun_names); do
            [ "$_hn" = "$H_ORIG" ] && continue
            case " $H_TRIED " in *" $_hn "*) continue ;; esac
            tun_parse "$(tun_file "$_hn")" >/dev/null 2>&1 || continue
            if [ "$T_TYPE" = amneziawg ] && [ "$FAKE_LINK" = 0 ] && ! awg_kernel_ok; then continue; fi
            case "$_bad" in *" ${T_EP%:*} "*) continue ;; esac
            _g=1; [ -n "$_cc" ] && [ "$(tun_country "$_hn")" = "$_cc" ] && _g=0
            _i=$((_i + 1))
            echo "$_g $(test_rank "$_hn") $_i $_hn"
        done | sort -n -k1,1 -k2,2 -k3,3 | awk '{ print $4; exit }'
    )
}

# notify TEXT - 0 when posted. One notification (always the same slot: a new one replaces
# the old). Posted as the shell user: HyperOS shows those, not root's.
notify() {
    [ "$S_NOTIFY" = 1 ] || return 1
    _m=$(printf '%s' "$1" | tr -cd 'A-Za-z0-9 .,:()/+_-')
    if "$SU" 2000 -c "$CMD notification post -S bigtext -t 'WG Shield' wg_shield '$_m'" >/dev/null 2>&1; then
        wlog INFO "notification: $_m"; unset _m; return 0
    fi
    wlog WARN "notification could not be shown: $_m"; unset _m
    return 1
}

# load tunnel NAME now (a fresh interface: new handshake); 0 = loaded
heal_load_tunnel() {
    live_reset
    "$IP" link del "$IFACE" 2>/dev/null
    rm -f "$STATE/loaded"
    tunnel_ensure "$1"
}

heal_status() {  # the status key recover=
    if [ -z "$H_ORIG" ]; then ST_RECOVER=""
    elif [ "$H_DONE" = 1 ]; then ST_RECOVER="failed"
    elif [ "$H_STEP" -le "$HEAL_RESTARTS" ]; then ST_RECOVER="restart $H_STEP/$HEAL_RESTARTS"
    else ST_RECOVER="switch $H_CUR"
    fi
    ST_RECOVER_FROM=$H_ORIG
}

# what the notification says about what was tried
heal_tried_text() {
    _n=0; for _t in $H_TRIED; do _n=$((_n + 1)); done
    _r="$HEAL_RESTARTS restarts"
    if [ "$_n" = 0 ]; then echo "$_r"
    elif [ "$_n" = 1 ]; then echo "$_r and 1 other tunnel ($(echo $H_TRIED))"
    else echo "$_r and $_n other tunnels ($(echo $H_TRIED | sed 's/ /, /g'))"
    fi
    unset _n _t _r
}

# next step; sets ST_STATE / ST_REASON for this tick
heal_next() {
    H_STEP=$((H_STEP + 1))
    if [ "$H_STEP" -le "$HEAL_RESTARTS" ]; then
        wlog WARN "recovery: $H_CUR does not answer - restart $H_STEP of $HEAL_RESTARTS"
        heal_load_tunnel "$H_CUR"
        H_AT=$(mono_now); heal_save
        ST_STATE=handshaking; ST_REASON=recovering; ST_HSAGE="-"
        return 0
    fi
    if [ "$S_AUTOSWITCH" = 1 ]; then
        _sw=0; for _t in $H_TRIED; do _sw=$((_sw + 1)); done
        while [ "$_sw" -lt "$HEAL_MAX_SWITCH" ]; do
            _c=$(heal_pick)
            [ -n "$_c" ] || break
            _sw=$((_sw + 1))
            H_TRIED="${H_TRIED:+$H_TRIED }$_c"; H_CUR=$_c
            S_ACTIVE=$_c; S_LAST=$_c; settings_save
            wlog WARN "recovery: switching to $_c ($_sw of at most $HEAL_MAX_SWITCH)"
            if heal_load_tunnel "$_c"; then
                H_AT=$(mono_now); heal_save
                ST_TUNNEL=$_c; ST_STATE=handshaking; ST_REASON=recovering; ST_HSAGE="-"
                return 0
            fi
            [ "$ERR" = resolving ] && { H_AT=$(mono_now); heal_save; ST_TUNNEL=$_c; ST_STATE=handshaking; ST_REASON=recovering; ST_HSAGE="-"; return 0; }
            wlog WARN "recovery: $_c cannot be used ($ERR)"
        done
        unset _sw _c _t
    fi
    # nothing helped: back to the tunnel the user picked, stay down
    if [ "$H_CUR" != "$H_ORIG" ]; then
        S_ACTIVE=$H_ORIG; S_LAST=$H_ORIG; settings_save
        H_CUR=$H_ORIG
        heal_load_tunnel "$H_ORIG"
        wlog INFO "recovery: back to $H_ORIG"
    fi
    H_AT=$(mono_now)
    ST_TUNNEL=$H_ORIG; ST_STATE=down; ST_HSAGE="-"
    # handshakes but no answer through it, or no handshake at all
    if [ "$(wg_handshake)" -gt 0 ] 2>/dev/null; then ST_REASON=no_answer; else ST_REASON=no_handshake; fi
    H_DONE=1
    if [ "$S_KILLSWITCH" = 1 ]; then _what="No internet - the kill switch blocks everything until a tunnel answers."
    else _what="Direct connection without the tunnel (kill switch off)."; fi
    _hint=""; [ "$S_AUTOSWITCH" = 1 ] || _hint=" Pick another tunnel in WG Shield, or turn on Auto-switch."
    wlog WARN "recovery: nothing helped ($(heal_tried_text)) - $H_ORIG stays down"
    notify "$H_ORIG does not answer. $(heal_tried_text) did not help. $_what$_hint" && H_NOTIFIED=1
    heal_save
    unset _what _hint
}

# called by wgs_tick once the tunnel is loaded and its state is known
# (ST_STATE up / handshaking / down); may change the active tunnel
heal_tick() {
    heal_load
    if [ -n "$H_ORIG" ]; then
        # the user picked another tunnel, or the network changed: start over
        if [ "$H_CUR" != "$S_ACTIVE" ] || [ "$H_DEF" != "$DEF" ]; then
            [ "$H_CUR" != "$S_ACTIVE" ] && wlog INFO "recovery: tunnel changed by the user - stopped"
            heal_clear
        fi
    fi
    case "$ST_STATE" in
        up)
            if [ -n "$H_ORIG" ]; then
                # a handshake alone is not enough: wait for an answer through the tunnel
                if tun_pingable "$H_CUR" && [ "$(cat "$STATE/alive_at" 2>/dev/null || echo -1)" -lt $(( H_AT * 100 )) ] 2>/dev/null; then
                    # (state stays up meanwhile: traffic goes into the tunnel, so the ping can tell)
                    if [ "$H_DONE" != 1 ]; then
                        if [ $(( $(mono_now) - H_AT )) -ge "$HEAL_WAIT" ]; then heal_next; else ST_REASON=recovering; fi
                        return 0
                    fi
                    # everything failed before: with the kill switch on, the ping
                    # (every 15 s while down) says when it works again; off, nothing
                    # is pinged while down, so a new handshake has to do
                    if [ "$S_KILLSWITCH" = 1 ]; then ST_STATE=down; ST_REASON=no_answer; return 0; fi
                fi
                if [ "$H_DONE" = 1 ]; then
                    wlog INFO "recovery: $H_CUR answers again"
                    [ "$H_NOTIFIED" = 1 ] && notify "$H_CUR answers again - protected."
                elif [ "$H_CUR" != "$H_ORIG" ]; then
                    wlog INFO "recovery: protected again through $H_CUR (switched from $H_ORIG)"
                    notify "$H_ORIG does not answer, $HEAL_RESTARTS restarts did not help. Switched to $H_CUR - protected again."
                else
                    wlog INFO "recovery: $H_CUR answers again after restart $H_STEP"
                fi
                heal_clear
            fi
            ;;
        down)
            case "$ST_REASON" in no_handshake|no_answer) : ;; *) return 0 ;; esac
            [ -n "$DEF" ] || return 0
            [ "$H_DONE" = 1 ] && return 0
            if [ -z "$H_ORIG" ]; then
                H_ORIG=$S_ACTIVE; H_CUR=$S_ACTIVE; H_STEP=0; H_TRIED=""; H_DEF=$DEF
            elif [ $(( $(mono_now) - H_AT )) -lt "$HEAL_WAIT" ]; then
                ST_STATE=handshaking; ST_REASON=recovering   # the last step still has time
                return 0
            fi
            heal_next
            ;;
        handshaking)
            [ -n "$H_ORIG" ] || return 0
            if [ "$H_DONE" = 1 ]; then
                # back on the user's tunnel after everything failed: it is
                # still trying, but this is no new connection
                ST_STATE=down; ST_REASON=no_handshake
            elif [ $(( $(mono_now) - H_AT )) -ge "$HEAL_WAIT" ]; then
                heal_next
            else
                ST_REASON=recovering
            fi
            ;;
    esac
}
