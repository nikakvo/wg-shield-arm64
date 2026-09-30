# WG Shield Arm64 - routing (plain Linux policy routing, invisible to Android)
#
# Our ip rules sit before netd's (prefs 5000-5021, netd starts at 10000):
#   5000  iif lo to <endpoint>/32          lookup <default net table>   tunnel's own UDP
#   5010  iif lo lookup local_network suppress_prefixlength 0            hotspot / local
#   5011  iif lo lookup <default>_local suppress_prefixlength 0          LAN (only while an Android VPN exists)
#   5012  iif lo lookup <default table> suppress_prefixlength 0          LAN, gateway
#   5020  iif lo fwmark 0x0/0x10000        lookup 51820                  all traffic not bound to a network
#   5021  iif lo fwmark <netId>/0xffff     lookup 51820                  traffic bound to the default network
# IPv6: 5010-5012 the same; 5020/5021 unreachable (the tunnel is IPv4-only, nothing may go around it).
# Table 51820: default dev wgs0 + unreachable default metric 4096 (kill switch backstop).
# Sockets bound to another network (IMS / VoLTE / MMS) keep netd's routing.

local_table() {
    t=$(awk '$2 == "local_network" { print $1; exit }' "$RT_TABLES" 2>/dev/null)
    echo "${t:-97}"
}

detect_net() {
    rules=$("$IP" rule 2>/dev/null)
    # 31000 = netd's default-network rule; 16000 = explicit rule carrying its netId
    DEF=$(echo "$rules" | awk '$1 == "31000:" { for (i = 1; i <= NF; i++) if ($i == "lookup") { print $(i + 1); exit } }')
    NID=""; LOCALT=""
    if [ -n "$DEF" ]; then
        m=$(echo "$rules" | awk -v t="$DEF" '$1 == "16000:" && $NF == t && $0 !~ /uidrange/ { for (i = 1; i <= NF; i++) if ($i == "fwmark") { print $(i + 1); exit } }')
        [ -n "$m" ] && NID=$(printf '0x%x' $(( ${m%%/*} & 0xffff )))
        echo "$rules" | awk -v t="${DEF}_local" '$NF == t { f = 1 } END { exit !f }' && LOCALT="${DEF}_local"
    fi
    # an Android VPN (WireGuard app, Proton, v2rayNG...) = netd's secure-VPN uid rule
    ANDVPN=$(echo "$rules" | awk '$1 == "13000:" && /uidrange/ { for (i = 1; i <= NF; i++) if ($i == "lookup") { print $(i + 1); exit } }')
}

rules_del() {
    for p in $PREFS; do
        while "$IP" rule del pref "$p" 2>/dev/null; do :; done
        while "$IP" -6 rule del pref "$p" 2>/dev/null; do :; done
    done
}

# IPv6 through the tunnel (config with an IPv6 address and ::/0, and IPv6 on
# in the kernel - DNSCrypt Proxy's ipv4 mode turns it off everywhere).
# Sets V6ON=1 when wgs0 carries the tunnel's IPv6 address and route.
PROC6="${WGS_PROC6:-/proc/sys/net/ipv6/conf}"
v6_kernel_on() { [ "$(cat "$PROC6/all/disable_ipv6" 2>/dev/null)" = 0 ]; }
v6_ensure() {
    V6ON=0
    [ "$T_V6" = 1 ] && [ -n "$T_ADDR6" ] || return 0
    v6_kernel_on || return 0
    [ "$(cat "$PROC6/$IFACE/disable_ipv6" 2>/dev/null)" = 0 ] || return 0
    a=${T_ADDR6%/*}
    "$IP" -6 addr show dev "$IFACE" 2>/dev/null | grep -q "inet6 $a/" ||
        "$IP" -6 addr add "$T_ADDR6" dev "$IFACE" nodad 2>/dev/null
    "$IP" -6 addr show dev "$IFACE" 2>/dev/null | grep -q "inet6 $a/" || return 0
    r=$("$IP" -6 route show table "$TABLE" 2>/dev/null)
    case "$r" in *"dev $IFACE"*) : ;; *) "$IP" -6 route replace default dev "$IFACE" table "$TABLE" 2>/dev/null ;; esac
    case "$r" in *unreachable*) : ;; *) "$IP" -6 route replace unreachable default metric 4096 table "$TABLE" 2>/dev/null ;; esac
    "$IP" -6 route show table "$TABLE" 2>/dev/null | grep -q "dev $IFACE" && V6ON=1
}

# rules_add CAPTURE(0|1) - uses DEF NID LOCALT T_EPIP V6ON
rules_add() {
    lt=$(local_table)
    for fam in -4 -6; do
        "$IP" $fam rule add pref 5010 iif lo lookup "$lt" suppress_prefixlength 0 2>/dev/null
        if [ -n "$DEF" ]; then
            [ -n "$LOCALT" ] && "$IP" $fam rule add pref 5011 iif lo lookup "$LOCALT" suppress_prefixlength 0 2>/dev/null
            "$IP" $fam rule add pref 5012 iif lo lookup "$DEF" suppress_prefixlength 0 2>/dev/null
        fi
    done
    [ -n "$DEF" ] && [ -n "$T_EPIP" ] && "$IP" rule add pref 5000 iif lo to "$T_EPIP/32" lookup "$DEF" 2>/dev/null
    [ "$1" = 1 ] || return 0
    if [ "$V6ON" = 1 ]; then v6act="lookup $TABLE"; else v6act=unreachable; fi
    "$IP" rule add pref 5020 iif lo fwmark 0x0/0x10000 lookup "$TABLE" 2>/dev/null
    "$IP" -6 rule add pref 5020 iif lo fwmark 0x0/0x10000 $v6act 2>/dev/null
    if [ -n "$NID" ]; then
        "$IP" rule add pref 5021 iif lo fwmark "$NID/0xffff" lookup "$TABLE" 2>/dev/null
        "$IP" -6 rule add pref 5021 iif lo fwmark "$NID/0xffff" $v6act 2>/dev/null
    fi
}

rules_sig() {
    { "$IP" rule 2>/dev/null; "$IP" -6 rule 2>/dev/null; } | grep -E '^50[0-9][0-9]:'
    "$IP" route show table "$TABLE" 2>/dev/null
    "$IP" -6 route show table "$TABLE" 2>/dev/null
}

routes_ensure() {
    r=$("$IP" route show table "$TABLE" 2>/dev/null)
    case "$r" in *"dev $IFACE"*) : ;; *) "$IP" route replace default dev "$IFACE" table "$TABLE" 2>/dev/null ;; esac
    case "$r" in *unreachable*) : ;; *) "$IP" route replace unreachable default metric 4096 table "$TABLE" 2>/dev/null ;; esac
}

# resolve_host NAME -> first IPv4. Plain DNS to Quad9, sent around the tunnel
# for a moment (rule 5001): the tunnel is not up yet, and these are the
# resolvers DNSCrypt Proxy lets root query directly (its bootstrap exemption).
RESOLVERS="9.9.9.9 149.112.112.112"
resolve_host() {
    [ -n "$DEF" ] || return 1
    for srv in $RESOLVERS; do
        "$IP" rule add pref 5001 iif lo to "$srv/32" lookup "$DEF" 2>/dev/null
        out=$("$BB" timeout 6 "$BB" nslookup "$1" "$srv" 2>/dev/null)
        while "$IP" rule del pref 5001 2>/dev/null; do :; done
        a=$(echo "$out" | awk '
            /^Name:/ { n = 1; next }
            n { for (i = 1; i <= NF; i++) { f = $i; sub(/:53$/, "", f)
                if (f ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print f; exit } } }')
        [ -n "$a" ] && { echo "$a"; return 0; }
    done
    return 1
}

# boot guard (post-fs-data): block everything not bound to a network until the tunnel is up
boot_guard() {
    "$IP" route replace unreachable default metric 4096 table "$TABLE" 2>/dev/null
    "$IP" rule add pref 5020 iif lo fwmark 0x0/0x10000 lookup "$TABLE" 2>/dev/null
    "$IP" -6 rule add pref 5020 iif lo fwmark 0x0/0x10000 unreachable 2>/dev/null
}

iface_exists() { "$IP" link show "$IFACE" >/dev/null 2>&1; }

anything_present() {
    iface_exists && return 0
    [ -n "$(rules_sig)" ]
}

teardown() {
    rules_del
    "$IP" route flush table "$TABLE" 2>/dev/null
    "$IP" -6 route flush table "$TABLE" 2>/dev/null
    "$IP" link del "$IFACE" 2>/dev/null
    rm -f "$STATE/loaded" "$STATE/tunnel.info" "$STATE/rules.key" "$STATE/rules.sig" "$STATE/up_since" "$STATE/resolved_at"
}

# tunnel_ensure NAME - iface exists, carries NAME's keys/peer/address, is up.
# Sets T_ADDR T_EP T_EPIP T_EPHOST T_PORT T_MTU. Returns 1 with ERR set on a
# hard failure, 3 when a host-name endpoint cannot be resolved yet (retried).
tunnel_ensure() {
    name=$1; f=$(tun_file "$name"); ERR=""
    ck="$name $(cksum < "$f" 2>/dev/null | awk '{ print $1 }')"
    fresh=0
    if ! iface_exists; then
        "$IP" link add "$IFACE" type "$LINKTYPE" 2>/dev/null || { ERR=no_kernel_wireguard; return 1; }
        rm -f "$STATE/loaded"; fresh=1
    fi
    if [ "$(cat "$STATE/loaded" 2>/dev/null)" != "$ck" ]; then
        tun_parse "$f" || { ERR="invalid_tunnel: $T_ERR"; return 1; }
        if [ -n "$T_EPHOST" ]; then
            T_EPIP=$(resolve_host "$T_EPHOST") || { ERR=resolving; T_EPIP=""; routes_ensure; return 3; }
            wlog INFO "endpoint $T_EPHOST is $T_EPIP"
            mono_now > "$STATE/resolved_at"
        fi
        if [ "$LINKTYPE" = wireguard ]; then
            [ -x "$WG" ] || { ERR=wg_tool_missing; return 1; }
            sc="$STATE/setconf.$$"
            tun_setconf "$f" "$sc" "$( [ -n "$T_EPHOST" ] && echo "$T_EPIP:$T_PORT")"
            "$WG" setconf "$IFACE" "$sc" 2>"$STATE/wg.err"; rc=$?
            rm -f "$sc"
            if [ "$rc" != 0 ]; then
                # wg quotes the offending line between ` and ' - that can be a key: cut it
                e=$(sed "s/\`[^']*'/\`…'/g" "$STATE/wg.err" 2>/dev/null | tr '\n' ' ')
                wlog ERROR "wg setconf ($name): ${e:-no message}"
                rm -f "$STATE/wg.err"
                ERR=wg_setconf_failed; return 1
            fi
            rm -f "$STATE/wg.err"
        fi
        "$IP" addr flush dev "$IFACE" 2>/dev/null
        "$IP" addr add "$T_ADDR" dev "$IFACE" 2>/dev/null
        info_save
        echo "$ck" > "$STATE/loaded"
        mono_now > "$STATE/up_since"
        [ "$fresh" = 1 ] && wlog INFO "tunnel $name up (endpoint $T_EP)" || wlog INFO "tunnel $name loaded (endpoint $T_EP)"
    else
        { read -r T_ADDR; read -r T_EP; read -r T_EPIP; read -r T_MTU; read -r T_EPHOST; read -r T_PORT; read -r T_ADDR6; read -r T_V6; } 2>/dev/null < "$STATE/tunnel.info"
    fi
    case "$("$IP" link show "$IFACE" 2>/dev/null | head -n1)" in
        *",UP"*|*"<UP"*) : ;;
        *) "$IP" link set "$IFACE" mtu "${T_MTU:-1420}" up 2>/dev/null ;;
    esac
    routes_ensure
    v6_ensure
    return 0
}

info_save() { printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$T_ADDR" "$T_EP" "$T_EPIP" "$T_MTU" "$T_EPHOST" "$T_PORT" "$T_ADDR6" "$T_V6" > "$STATE/tunnel.info"; }

# a host-name endpoint whose tunnel stopped answering: its address may have
# changed (dynamic DNS) - look it up again, at most once a minute
reresolve() {
    [ -n "$T_EPHOST" ] || return 0
    last=$(cat "$STATE/resolved_at" 2>/dev/null || echo 0)
    [ $(( $(mono_now) - last )) -ge 60 ] || return 0
    mono_now > "$STATE/resolved_at"
    new=$(resolve_host "$T_EPHOST") || return 0
    [ "$new" != "$T_EPIP" ] || return 0
    if [ "$LINKTYPE" = wireguard ]; then
        pk=$("$WG" show "$IFACE" peers 2>/dev/null | head -n1)
        [ -n "$pk" ] && "$WG" set "$IFACE" peer "$pk" endpoint "$new:$T_PORT" 2>/dev/null
    fi
    wlog INFO "endpoint $T_EPHOST moved: $T_EPIP -> $new"
    T_EPIP=$new; info_save
}

wg_handshake() {  # epoch of the latest handshake, 0 = never
    [ "$LINKTYPE" = wireguard ] || { cat "$STATE/fake_hs" 2>/dev/null || echo 0; return; }
    h=$("$WG" show "$IFACE" latest-handshakes 2>/dev/null | awk '{ print $2; exit }')
    echo "${h:-0}"
}

wg_transfer() {
    ST_RX=""; ST_TX=""
    [ "$LINKTYPE" = wireguard ] || return 0
    set -- $("$WG" show "$IFACE" transfer 2>/dev/null | awk '{ print $2, $3; exit }')
    ST_RX=$1; ST_TX=$2
}

pause_left() {  # seconds left, 0 = not paused
    u=$(cat "$STATE/pause_until" 2>/dev/null)
    [ -n "$u" ] || { echo 0; return; }
    l=$(( u - $(mono_now) ))
    if [ "$l" -gt 0 ]; then echo "$l"; else rm -f "$STATE/pause_until"; echo 0; fi
}

# ---- one watchdog tick (caller holds the lock) ---------------------------------
wgs_tick() {
    settings_load
    detect_net
    prev=$(cat "$STATE/last_state" 2>/dev/null)
    ST_TUNNEL=$S_ACTIVE; ST_ENDPOINT=""; ST_HSAGE="-"; ST_DEF=$DEF; ST_ANDVPN=$ANDVPN
    ST_REASON=""; ST_RX=""; ST_TX=""; ST_EPHOST=""; ST_IPV6=""; V6ON=0; ST_PAUSELEFT=$(pause_left)

    if [ -z "$S_ACTIVE" ]; then
        ST_STATE=off
    elif [ "$ST_PAUSELEFT" -gt 0 ]; then
        ST_STATE=paused; ST_REASON=user
    elif [ -n "$ANDVPN" ]; then
        ST_STATE=paused; ST_REASON="android_vpn"
    elif ! tun_exists "$S_ACTIVE"; then
        ST_STATE=error; ST_REASON=tunnel_missing
    else
        ST_STATE=on
    fi

    if [ "$ST_STATE" != on ]; then
        if anything_present; then
            shutting_down && return 2
            teardown
        fi
        [ "$ST_PAUSELEFT" = 0 ] && ST_PAUSELEFT=""
    else
        ST_PAUSELEFT=""
        shutting_down && return 2
        tunnel_ensure "$S_ACTIVE"; rc=$?
        if [ "$rc" = 1 ]; then
            teardown
            ST_STATE=error; ST_REASON=$ERR
        else
            ST_ENDPOINT=""; [ -n "$T_EPIP" ] && ST_ENDPOINT="$T_EPIP:$T_PORT"
            [ -n "$T_EPHOST" ] && ST_EPHOST=$T_EP
            if [ "$rc" = 3 ]; then
                ST_STATE=handshaking; ST_REASON=resolving
                [ -n "$DEF" ] || ST_REASON=no_network
            else
                hs=$(wg_handshake); now=$(epoch_now)
                if [ "$hs" -gt 0 ] 2>/dev/null; then
                    age=$(( now - hs )); [ "$age" -lt 0 ] && age=0
                    ST_HSAGE=$age
                    if [ "$age" -le "$DOWN_AFTER" ]; then ST_STATE=up; else ST_STATE=down; ST_REASON=no_handshake; fi
                else
                    since=$(( $(mono_now) - $(cat "$STATE/up_since" 2>/dev/null || mono_now) ))
                    if [ "$since" -lt "$DOWN_AFTER" ]; then ST_STATE=handshaking; else ST_STATE=down; ST_REASON=no_handshake; fi
                fi
                [ -n "$DEF" ] || { [ "$ST_STATE" = up ] || ST_REASON=no_network; }
                if [ -n "$T_EPHOST" ] && [ -n "$DEF" ]; then
                    case "$ST_STATE" in down) reresolve; ST_ENDPOINT="$T_EPIP:$T_PORT" ;; esac
                fi
            fi
            capture=1
            [ "$S_KILLSWITCH" = 0 ] && [ "$ST_STATE" != up ] && capture=0
            key="$DEF|$NID|$LOCALT|$T_EPIP|$capture|$(local_table)|$V6ON"
            oldkey=$(cat "$STATE/rules.key" 2>/dev/null)
            sig=$(rules_sig | cksum)
            if [ "$key" != "$oldkey" ] || [ "$sig" != "$(cat "$STATE/rules.sig" 2>/dev/null)" ]; then
                shutting_down && return 2
                rules_del
                rules_add "$capture"
                echo "$key" > "$STATE/rules.key"
                rules_sig | cksum > "$STATE/rules.sig"
                if [ -z "$oldkey" ]; then
                    wlog INFO "routing on: network ${DEF:-none} (netId ${NID:-none}), kill switch $S_KILLSWITCH, IPv6 $( [ "$V6ON" = 1 ] && echo 'through the tunnel' || echo blocked)"
                elif [ "$key" != "$oldkey" ]; then
                    wlog INFO "routing updated: network ${DEF:-none} (netId ${NID:-none}), capture $capture, IPv6 $( [ "$V6ON" = 1 ] && echo tunnel || echo blocked)"
                else
                    wlog WARN "routing rules were changed by someone else - repaired"
                fi
            fi
            wg_transfer
            if [ "$V6ON" = 1 ]; then ST_IPV6=tunnel; elif v6_kernel_on; then ST_IPV6=blocked; else ST_IPV6=off; fi
        fi
    fi

    cur="$ST_STATE $ST_REASON $ST_TUNNEL"
    if [ "$cur" != "$prev" ]; then
        echo "$cur" > "$STATE/last_state"
        case "$ST_STATE" in
            error) wlog ERROR "state: error ($ST_REASON) - direct connection" ;;
            down) wlog WARN "state: down ($ST_REASON)$( [ "$S_KILLSWITCH" = 1 ] && echo ' - kill switch blocks traffic')" ;;
            *) wlog INFO "state: $ST_STATE${ST_REASON:+ ($ST_REASON)}${ST_TUNNEL:+ - $ST_TUNNEL}" ;;
        esac
    fi
    status_write
    module_desc
    return 0
}
