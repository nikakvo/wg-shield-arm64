# WG Shield Arm64 - routing (plain Linux policy routing, invisible to Android)
#
# Our ip rules sit before netd's (prefs 5000-5021, netd starts at 10000):
#   5000  iif lo to <endpoint>/32          lookup <default net table>   tunnel's own UDP
#   5010  iif lo lookup local_network suppress_prefixlength 0            hotspot / local
#   5011  iif lo lookup <default>_local suppress_prefixlength 0          LAN (only while an Android VPN exists)
#   5012  iif lo lookup <default table> suppress_prefixlength 0          LAN, gateway
#   5013  iif lo fwmark <other>/0xffff lookup <its table> suppress_prefixlength 0   its LAN stays local
#   5014  iif lo fwmark <net>/0xffff uidrange <uid>-<uid> lookup <its table>      Android's own check of it, login page
#   5020  iif lo fwmark 0x0/0x10000        lookup 51820                  all traffic not bound to a network
#   5021  iif lo fwmark <netId>/0xffff     lookup 51820                  traffic bound to the default network
#   5022  iif lo fwmark <other>/0xffff     lookup 51820                  traffic bound to another internet network
# IPv6: 5010-5014 the same; 5020-5022 through the tunnel or unreachable (nothing may go around it).
# Table 51820: default dev wgs0 + unreachable default metric 4096 (kill switch backstop).
#
# "Other" networks (5013/5014/5022): every network that is not the default
# one but carries internet - mobile data kept up in the background while
# Wi-Fi is the default, a Wi-Fi that is not the default yet, ... Apps and
# system parts bind sockets to such a network explicitly (Google's push
# service opens its connection on a new Wi-Fi a split second after Android
# has checked it); without 5022 that traffic would go around the tunnel.
# A new network is captured the moment netd creates it (fast_capture, from
# the watchdog's ip monitor), long before Android has checked it.
# Android's own checks (NetworkStack, uid 1073) and the hotel / airport
# login page (the captive portal login app) always stay on the network they
# are for (5014, also for the default network), so a broken Wi-Fi is never
# taken for a working one and a login page can open.
# Sockets bound to a carrier service network (IMS / VoLTE, MMS without
# internet - restricted or without INTERNET) keep netd's routing.

# tbl_num NAME -> the table's number. Rules are always written with numbers:
# netd removes an interface's name from rt_tables when the network goes, and
# a rule written with the name could then not be deleted any more (seen on
# the phone: "lookup 1028" left behind); it also adds the name a moment
# after the network's first rules.
tbl_num() {
    case "$1" in
        ""|*[!0-9]*) _tn=$(awk -v n="$1" '$2 == n { print $1; exit }' "$RT_TABLES" 2>/dev/null); echo "${_tn:-$1}"; unset _tn ;;
        *) echo "$1" ;;
    esac
}

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
    DEFN=$(tbl_num "$DEF"); LOCALTN=$(tbl_num "$LOCALT")
    # an Android VPN (WireGuard app, Proton, v2rayNG...) = netd's secure-VPN uid rule
    ANDVPN=$(echo "$rules" | awk '$1 == "13000:" && /uidrange/ { for (i = 1; i <= NF; i++) if ($i == "lookup") { print $(i + 1); exit } }')
    # every network netd knows: its explicit 16000 rule "fwmark <mark>/<mask>
    # lookup <iface>" (local_network and VPN uid rules left out). Lines
    # "<netId hex> <netId dec> <permission> <table> <table number>"; permission = bits 18-19
    # of the mark: 0 none, 1 NETWORK (a background network), 2/3 SYSTEM
    # (restricted: IMS and other carrier service networks).
    NETS_ALL=""
    _oifs=$IFS; IFS='
'
    for _p in $(echo "$rules" | awk '$1 == "16000:" && $0 !~ /uidrange/ && $NF != "local_network" { for (i = 1; i <= NF; i++) if ($i == "fwmark") { split($(i + 1), a, "/"); print a[1] " " $NF; break } }'); do
        _m=${_p%% *}; _t=${_p#* }
        _n=$(( _m & 0xffff ))
        NETS_ALL="$NETS_ALL$(printf '0x%x' "$_n") $_n $(( (_m >> 18) & 3 )) $_t $(tbl_num "$_t")
"
    done
    IFS=$_oifs
    # netd re-adds rules in another order now and then: sort by netId
    NETS_ALL=$(printf '%s' "$NETS_ALL" | sort -n -k2)
    [ -n "$NETS_ALL" ] && NETS_ALL="$NETS_ALL
"
    unset _p _m _t _n _oifs
}

# ---- other internet networks (rules 5013 / 5014 / 5022) ------------------------
NETSTACK_UID=1073   # AID_NETWORK_STACK: Android's validation / captive portal checks
DUMPSYS="${WGS_DUMPSYS:-/system/bin/dumpsys}"
NETS_RECHECK=${WGS_NETS_RECHECK:-10}     # s: how often a network that is not validated yet is looked at again

# "<netId> <capabilities>" for every network ConnectivityService has
net_caps() {
    "$DUMPSYS" connectivity 2>/dev/null | awk '
        /NetworkAgentInfo\{network\{[0-9]+\}/ {
            s = $0; sub(/.*NetworkAgentInfo\{network\{/, "", s); sub(/\}.*/, "", s)
            if (seen[s]++) next
            c = "-"; if (match($0, /Capabilities: [^ ]+/)) c = substr($0, RSTART + 14, RLENGTH - 14)
            print s, c
        }'
}

# nets_classify - uses NETS_ALL DEF; sets
#   EXTRA     "<netId hex>:<table> ..." other networks to send through the tunnel
#   NETS_ST   "<table>/<class>,..." for the status file; class = default |
#             tunnel | checking (not validated yet) | outside (carrier service
#             network, or no internet)
# dumpsys only runs when the set of networks changed (or one is still being
# checked by Android, at most every NETS_RECHECK s); the answer is kept in
# $STATE/nets.
nets_classify() {
    EXTRA=""; EXTRA_NAMES=""; NETS_ST=""
    [ -n "$DEF" ] || return 0
    _key=$(printf '%s' "$NETS_ALL" | tr '\n' ';')"|$NID"
    _c="$STATE/nets"
    _old=$(head -n 1 "$_c" 2>/dev/null)
    _run=1
    if [ "$_old" = "$_key" ]; then
        _run=0
        if awk '$3 == "checking" { f = 1 } END { exit !f }' "$_c" 2>/dev/null; then
            _at=$(sed -n 2p "$_c" 2>/dev/null)
            [ $(( $(mono_now) - ${_at:-0} )) -ge "$NETS_RECHECK" ] && _run=1
        fi
    fi
    if [ "$_run" = 1 ]; then
        _caps=$(net_caps)
        _body=""
        _oifs=$IFS; IFS='
'
        for _l in $NETS_ALL; do
            IFS=' '; set -- $_l; IFS='
'
            # $1 netId hex, $2 netId, $3 permission, $4 table
            if [ "$1" = "$NID" ]; then _cl=default
            elif [ "$3" -ge 2 ]; then _cl=outside
            else
                _cp=$(echo "$_caps" | awk -v n="$2" '$1 == n { print $2; exit }')
                case "&$_cp&" in
                    *"&INTERNET&"*) case "&$_cp&" in
                        *"&NOT_RESTRICTED&"*) case "&$_cp&" in *"&VALIDATED&"*) _cl=tunnel ;; *) _cl=checking ;; esac ;;
                        *) _cl=outside ;; esac ;;
                    "&&") _cl=checking ;;          # not in dumpsys (yet): captured, look again soon
                    *) _cl=outside ;;              # e.g. an MMS-only network
                esac
            fi
            _body="$_body$1 $4 $_cl $5
"
        done
        IFS=$_oifs
        { echo "$_key"; mono_now; printf '%s' "$_body"; } > "$_c.tmp.$$" && mv -f "$_c.tmp.$$" "$_c"
    fi
    _oifs=$IFS; IFS='
'
    for _l in $(tail -n +3 "$_c" 2>/dev/null); do
        IFS=' '; set -- $_l; IFS='
'
        NETS_ST="$NETS_ST${NETS_ST:+,}$2/$3"
        case "$3" in tunnel|checking) EXTRA="$EXTRA${EXTRA:+ }$1:${4:-$2}"; EXTRA_NAMES="$EXTRA_NAMES${EXTRA_NAMES:+, }$2" ;; esac
    done
    IFS=$_oifs
    unset _key _c _old _run _at _caps _body _l _cl _cp _oifs
}

rules_del() {
    for p in $PREFS; do
        while "$IP" rule del pref "$p" 2>/dev/null; do :; done
        while "$IP" -6 rule del pref "$p" 2>/dev/null; do :; done
    done
}

# IPv6 through the tunnel (config with an IPv6 address and ::/0, and IPv6 on
# for the phone). Sets V6ON=1 when wgs0 carries the tunnel's IPv6 address
# and route.
#
# DNSCrypt Proxy's "ipv4" IP mode means no IPv6 for the phone. Up to its
# r21 it switched IPv6 off in the kernel; since r22 the kernel keeps IPv6
# (the carrier's VoLTE network needs it) and DNSCrypt blocks it in the
# firewall instead - so its setting is read as well. Settings file: r22
# keeps it in /data/adb/dnscrypt-proxy/, r21 and older at the top of
# /data/adb.
PROC6="${WGS_PROC6:-/proc/sys/net/ipv6/conf}"
DNSC_MOD="${WGS_MODULES:-/data/adb/modules}/dnscrypt-proxy-android"
DNSC_ADB="${WGS_ADB:-/data/adb}"
dnsc_conf() {
    if [ -f "$DNSC_ADB/dnscrypt-proxy/settings.conf" ]; then echo "$DNSC_ADB/dnscrypt-proxy/settings.conf"
    else echo "$DNSC_ADB/dnscrypt-proxy-android.conf"; fi
}
dnsc_active() { [ -d "$DNSC_MOD" ] && [ ! -f "$DNSC_MOD/disable" ] && [ ! -f "$DNSC_MOD/remove" ]; }
dnsc_ipv4_only() {
    dnsc_active || return 1
    [ "$(sed -n 's/^IP_MODE=//p' "$(dnsc_conf)" 2>/dev/null | tail -n 1)" = ipv4 ]
}
v6_kernel_on() { [ "$(cat "$PROC6/all/disable_ipv6" 2>/dev/null)" = 0 ] && ! dnsc_ipv4_only; }
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

# Android's own network checks and the hotel / airport login page must go
# out on the network they are for, never through the tunnel: NetworkStack
# (validation, captive portal detection) and the captive portal login app.
# The login app's uid is looked up once (pm is slow) and kept in
# $STATE/exempt_uids.
PM="${WGS_PM:-/system/bin/pm}"
exempt_uids() {
    _f="$STATE/exempt_uids"
    # the package manager answers only once Android has started: until then
    # (early boot) NetworkStack alone, and ask again at the next tick
    if [ ! -f "$_f" ] && [ "$("$GETPROP" sys.boot_completed 2>/dev/null)" = 1 ]; then
        _p=$("$PM" list packages -U 2>/dev/null)
        if [ -n "$_p" ]; then
            _u=$(echo "$_p" | grep -i captiveportal | sed -n 's/.*uid:\([0-9][0-9]*\).*/\1/p' | sort -un | tr '\n' ' ')
            echo "$NETSTACK_UID $_u" > "$_f.tmp.$$" && mv -f "$_f.tmp.$$" "$_f"
            wlog INFO "kept on their own network: Android's network check (uid $NETSTACK_UID)${_u:+, captive portal login (uid ${_u% })}"
        fi
    fi
    if [ -f "$_f" ]; then cat "$_f"; else echo "$NETSTACK_UID"; fi
    unset _f _u _p
}

# rules_want CAPTURE(0|1) - every rule we want, one per line, as arguments
# for `ip` ("-4 rule add pref ..."). Uses DEF NID LOCALT T_EPIP V6ON EXTRA.
#   For every captured network (the default one and EXTRA):
#     5013  its LAN stays local (only for other networks; the default's is 5012)
#     5014  Android's checks and the login page stay on it
#     5021 / 5022  everything else bound to it -> tunnel
rules_want() {
    lt=$(local_table)
    for fam in -4 -6; do
        echo "$fam rule add pref 5010 iif lo lookup $lt suppress_prefixlength 0"
        if [ -n "$DEF" ]; then
            [ -n "$LOCALT" ] && echo "$fam rule add pref 5011 iif lo lookup $LOCALTN suppress_prefixlength 0"
            echo "$fam rule add pref 5012 iif lo lookup $DEFN suppress_prefixlength 0"
        fi
    done
    [ -n "$DEF" ] && [ -n "$T_EPIP" ] && echo "-4 rule add pref 5000 iif lo to $T_EPIP/32 lookup $DEFN"
    [ "$1" = 1 ] || return 0
    if [ "$V6ON" = 1 ]; then v6act="lookup $TABLE"; else v6act=unreachable; fi
    _ex=$(exempt_uids)
    echo "-4 rule add pref 5020 iif lo fwmark 0x0/0x10000 lookup $TABLE"
    echo "-6 rule add pref 5020 iif lo fwmark 0x0/0x10000 $v6act"
    if [ -n "$NID" ]; then
        for _u in $_ex; do for fam in -4 -6; do
            echo "$fam rule add pref 5014 iif lo fwmark $NID/0xffff uidrange $_u-$_u lookup $DEFN"
        done; done
        echo "-4 rule add pref 5021 iif lo fwmark $NID/0xffff lookup $TABLE"
        echo "-6 rule add pref 5021 iif lo fwmark $NID/0xffff $v6act"
    fi
    for _e in $EXTRA; do
        _n=${_e%%:*}; _t=${_e#*:}
        for fam in -4 -6; do
            echo "$fam rule add pref 5013 iif lo fwmark $_n/0xffff lookup $_t suppress_prefixlength 0"
            for _u in $_ex; do
                echo "$fam rule add pref 5014 iif lo fwmark $_n/0xffff uidrange $_u-$_u lookup $_t"
            done
        done
        echo "-4 rule add pref 5022 iif lo fwmark $_n/0xffff lookup $TABLE"
        echo "-6 rule add pref 5022 iif lo fwmark $_n/0xffff $v6act"
    done
    unset _e _n _t _u _ex
}

# ip_batch FILE - run "-4 rule ..." / "-6 rule ..." lines with one ip
# process per family (-force: go on after "exists" / "not found")
ip_batch() {
    grep '^-4 ' "$1" | sed 's/^-4 //' > "$1.4"
    grep '^-6 ' "$1" | sed 's/^-6 //' > "$1.6"
    [ -s "$1.4" ] && "$IP" -force -batch "$1.4" >/dev/null 2>&1
    [ -s "$1.6" ] && "$IP" -6 -force -batch "$1.6" >/dev/null 2>&1
    rm -f "$1.4" "$1.6"
}

# rules_apply CAPTURE - make the rules what rules_want says WITHOUT a gap:
# new rules are added first (an existing one just answers "exists"), only
# then the ones no longer wanted are deleted, then the wanted ones are added
# once more (a delete takes every rule that has at least the selectors
# given). $STATE/rules.want = what we put in last time, $STATE/rules.fast =
# what fast_capture put in since.
rules_apply() {
    rm -f "$STATE/rules.dirty"
    _b="$STATE/rules.batch.$$"
    rules_want "$1" > "$_b.new"
    [ -f "$STATE/rules.fast" ] && mv -f "$STATE/rules.fast" "$_b.fast"
    cat "$STATE/rules.want" "$_b.fast" 2>/dev/null | sort -u > "$_b.old"
    sort -u "$_b.new" > "$_b.sorted"
    ip_batch "$_b.new"
    # old lines that are not wanted any more -> delete
    grep -vxF -f "$_b.sorted" "$_b.old" | sed 's/ rule add / rule del /' > "$_b.del"
    if [ -s "$_b.del" ]; then
        ip_batch "$_b.del"
        ip_batch "$_b.new"
    fi
    mv -f "$_b.new" "$STATE/rules.want"
    rm -f "$_b.fast" "$_b.old" "$_b.sorted" "$_b.del"
    rules_check || {
        # an ip without -batch? one by one, then look again
        _oifs=$IFS; IFS='
'
        for _l in $(cat "$STATE/rules.want"); do IFS=' '; "$IP" $_l 2>/dev/null; IFS='
'; done
        IFS=$_oifs
        rules_check log
    }
    unset _b _l _oifs
}

# rules_check [log] - as many of our rules in the kernel as we want? (IPv4
# and IPv6 counted apart). With "log", a mismatch is written to the log with
# both lists, once per set of rules.
rules_check() {
    _w4=$(grep -c '^-4 ' "$STATE/rules.want" 2>/dev/null); _w6=$(grep -c '^-6 ' "$STATE/rules.want" 2>/dev/null)
    _h4=$("$IP" rule 2>/dev/null | grep -c '^50[0-9][0-9]:'); _h6=$("$IP" -6 rule 2>/dev/null | grep -c '^50[0-9][0-9]:')
    "$IP" -6 rule >/dev/null 2>&1 || _h6=$_w6   # no IPv6 at all
    _rc=0
    if [ "$_h4" != "$_w4" ] || [ "$_h6" != "$_w6" ]; then
        _rc=1
        _s=$(cksum < "$STATE/rules.want")
        if [ "$1" = log ] && [ "$_s" != "$(cat "$STATE/rules.bad" 2>/dev/null)" ]; then
            echo "$_s" > "$STATE/rules.bad"
            wlog WARN "rules check: IPv4 $_h4 of $_w4, IPv6 $_h6 of $_w6 - present: $("$IP" rule 2>/dev/null | grep -E '^50[0-9][0-9]:' | tr -s '\t ' ' ' | tr '\n' ';') wanted: $(grep '^-4 ' "$STATE/rules.want" | sed 's/^-4 rule add //' | tr '\n' ';')"
        fi
    fi
    unset _w4 _w6 _h4 _h6 _s
    return $_rc
}

# fast_capture LINE - called by the watchdog the moment netd adds a network
# (a "16000: ... fwmark <mark>/<mask> ... lookup <table>" line from ip
# monitor), before any tick and without waiting for the lock: a network that
# is not a carrier service one goes through the tunnel at once, with the same
# exceptions as above. The lines go to $STATE/rules.fast and rules.dirty
# makes the next tick check the network with dumpsys and keep or remove
# them. Only while the tunnel captures traffic (rules.key field 5 = 1).
fast_capture() {
    case "$1" in Deleted*|*uidrange*|*local_network*) return 0 ;; esac
    _k=$(cat "$STATE/rules.key" 2>/dev/null)
    [ "$(echo "$_k" | cut -d'|' -f5)" = 1 ] || return 0
    _m=$(echo "$1" | sed -n 's/.* fwmark \(0x[0-9a-f]*\)\/.*/\1/p')
    _t=$(tbl_num "$(echo "$1" | awk '{ print $NF }')")
    [ -n "$_m" ] && [ -n "$_t" ] || return 0
    [ $(( (_m >> 18) & 3 )) -ge 2 ] && return 0                  # carrier service network
    _n=$(printf '0x%x' $(( _m & 0xffff )))
    [ "$_n" = "$(echo "$_k" | cut -d'|' -f2)" ] && return 0      # the default network: 5021
    if [ "$(echo "$_k" | cut -d'|' -f7)" = 1 ]; then _v6="lookup $TABLE"; else _v6=unreachable; fi
    _f="$STATE/fast.$$"
    {
        echo "-4 rule add pref 5022 iif lo fwmark $_n/0xffff lookup $TABLE"
        echo "-6 rule add pref 5022 iif lo fwmark $_n/0xffff $_v6"
        for fam in -4 -6; do
            echo "$fam rule add pref 5013 iif lo fwmark $_n/0xffff lookup $_t suppress_prefixlength 0"
            for _u in $(cat "$STATE/exempt_uids" 2>/dev/null || echo "$NETSTACK_UID"); do
                echo "$fam rule add pref 5014 iif lo fwmark $_n/0xffff uidrange $_u-$_u lookup $_t"
            done
        done
    } > "$_f"
    ip_batch "$_f"
    cat "$_f" >> "$STATE/rules.fast"
    rm -f "$_f"
    : > "$STATE/rules.dirty"
    unset _k _m _t _n _v6 _u _f
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

# resolve_host NAME -> first IPv4. Plain DNS to Cloudflare, then Google, sent
# around the tunnel for a moment (rule 5001): the tunnel is not up yet, and
# these are the resolvers DNSCrypt Proxy lets root query directly (its
# bootstrap exemption, 2.1.20-r4+). Quad9 was used up to 2.7; it stops
# serving some countries. DNSCrypt Proxy before 2.1.20-r4 (versionCode 54)
# exempts only Quad9 - with such a version installed and enabled Quad9 is
# asked first (a query to the others would go into DNSCrypt, whose upstream
# is in the tunnel that is not up yet).
RESOLVERS="1.1.1.1 1.0.0.1 8.8.8.8"
RESOLVERS_OLD="9.9.9.9 149.112.112.112"
resolvers_now() {
    _rd="${WGS_MODULES:-/data/adb/modules}/dnscrypt-proxy-android"
    _rc=""
    if [ -f "$_rd/module.prop" ] && [ ! -f "$_rd/disable" ] && [ ! -f "$_rd/remove" ]; then
        _rc=$(sed -n 's/^versionCode=//p' "$_rd/module.prop" 2>/dev/null | head -n 1)
    fi
    case "$_rc" in
        ''|*[!0-9]*) echo "$RESOLVERS" ;;
        *) if [ "$_rc" -lt 54 ]; then echo "$RESOLVERS_OLD $RESOLVERS"; else echo "$RESOLVERS"; fi ;;
    esac
    unset _rd _rc
}
resolve_host() {
    [ -n "$DEF" ] || return 1
    for srv in $(resolvers_now); do
        # only root's DNS query (uid 0, port 53) goes around the tunnel: an
        # app talking to the same address (1.1.1.1 and 8.8.8.8 are DoT / DoH
        # servers too) stays in it meanwhile. An ip that does not know
        # "dport" in a rule: by uid only; none of both: every packet to the
        # resolver, as up to 2.8
        "$IP" rule add pref 5001 iif lo to "$srv/32" uidrange 0-0 dport 53 lookup "$DEFN" 2>/dev/null ||
            "$IP" rule add pref 5001 iif lo to "$srv/32" uidrange 0-0 lookup "$DEFN" 2>/dev/null ||
            "$IP" rule add pref 5001 iif lo to "$srv/32" lookup "$DEFN" 2>/dev/null
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

# Tunnel DNS. Android sends DNS to the resolvers of the network it is on.
# On mobile data those are the carrier's: rule 5021 sends the query into the
# tunnel, and a carrier's resolvers answer only their own subscribers, not
# the VPN server - every name lookup would time out while the tunnel is up.
# So app DNS (port 53) that the routing already sends INTO the tunnel (-o
# wgs0) goes to the tunnel's DNS instead: the first IPv4 server of the
# config's DNS line (the first IPv6 one while the tunnel carries IPv6).
# Only -o wgs0, on purpose:
# - Android's network check and the captive portal login are routed on
#   their own network (5014), never into wgs0, so they keep the network's
#   DNS. (iptables cannot tell them apart by uid: netd sends every app's DNS
#   as uid 0 - measured on the phone. Routing sees the real uid.)
# - carrier service networks (IMS, MMS) are not captured, never wgs0.
# - a resolver on the Wi-Fi LAN (the router) stays local (5012), as before;
#   the source address of a redirected query is already the tunnel's own.
# - local resolvers (127/8, DNSCrypt Proxy) are not wgs0.
# Nothing is done while DNSCrypt Proxy takes the phone's DNS (its nat OUTPUT
# DNAT to 127.x, the same check VPN Hotspot uses): it answers DNS itself and
# its own queries already go through the tunnel. When it is paused or in
# failsafe its DNAT is gone and the tunnel's DNS takes over.
# Every read is iptables-save (no xtables lock: wg-quick and other modules
# fail while someone holds it); iptables is called only to change rules.
#
# LAN DNS through the tunnel (setting LANDNS=1, off by default; IPv4): the
# router of a Wi-Fi sees every name the phone looks up, because its resolver
# is on the LAN and stays local (5012). With the setting on, and only while
# the tunnel is up (it answers), DNS that leaves through the interface of a
# captured network (the default one and every other validated network that
# goes through the tunnel; netd names a network's table after its interface)
# goes to the tunnel's DNS too. Such a query was routed to the LAN, so it
# carries the LAN source address: after the redirect it is routed again,
# into wgs0, and nat POSTROUTING (chain wgs_dnss) gives it the tunnel's own
# address, the only source the tunnel's server accepts. The chain then is:
#   -d 127.0.0.0/8, -d <tunnel DNS>          RETURN
#   mark of every network that stays outside RETURN (carrier service
#                                            networks, also when they share
#                                            an interface)
#   -o wgs0 udp/tcp 53                       DNAT (as without the setting)
#   mark of every network Android is still checking          RETURN
#   -d <resolvers of the endpoint lookup>    RETURN (resolve_host, 5001)
#   -o <interface> udp/tcp 53                DNAT, per captured network
# Not while the tunnel is connecting or down, also with the kill switch on:
# the network's resolver has to stay reachable then, or Android could not
# find a login page (hotel, airport) - its check cannot be told apart here
# (netd sends every DNS query as uid 0), so while the tunnel is up its
# lookups go to the tunnel's DNS as well. The IPv4 re-route after the
# redirect does not look at the uid, so they do arrive there. The IPv6 one
# does (measured), a redirected lookup of Android's check would leave on the
# network and be lost: a LAN resolver reached over IPv6 is left alone.
IPT="${WGS_IPT:-/system/bin/iptables}"
IPT6="${WGS_IPT6:-/system/bin/ip6tables}"
IPTS="${WGS_IPTS:-/system/bin/iptables-save}"
IPTS6="${WGS_IPTS6:-/system/bin/ip6tables-save}"
DNSCHAIN=wgs_dns
DNSSNAT=wgs_dnss    # nat POSTROUTING, only with LAN DNS through the tunnel; removed otherwise

# _nat_dump SAVE TOOL - the nat table as "-A ..." lines (iptables-save, else -S)
_nat_dump() { "$1" -t nat 2>/dev/null || "$2" -w -t nat -S 2>/dev/null; }
# _nat_has DUMP CHAIN - the chain exists
_nat_has() { printf '%s\n' "$1" | grep -qE "^(:$2 |-N $2\$)"; }
# _nat_cnt DUMP TEXT - number of lines containing TEXT
_nat_cnt() { printf '%s\n' "$1" | grep -cF -e "$2"; }
# dnsc_dnat DUMP - DNSCrypt Proxy (or another local resolver) takes the phone's DNS
dnsc_dnat() { printf '%s\n' "$1" | grep -E '^-A OUTPUT ' | grep -F -e '--dport 53' | grep -qF -e '-j DNAT --to-destination 127.'; }
# dns_dnat_to SERVER - DNAT target (IPv6 in brackets)
dns_dnat_to() { case "$1" in *:*) echo "[$1]:53" ;; *) echo "$1:53" ;; esac; }

dns_present() { [ -f "$STATE/dns.want" ] || [ -f "$STATE/dns6.want" ]; }
dns_del() {
    _dns_del "$IPT" "$IPTS" dns
    # IPv6: only when it was set up (no ip6tables-save on every teardown)
    [ -f "$STATE/dns6.want" ] && _dns_del "$IPT6" "$IPTS6" dns6
    return 0
}
_dns_del() {  # _dns_del TOOL SAVE STATENAME [DUMP]
    _dd=${4-$(_nat_dump "$2" "$1")}
    _dj=$(_nat_cnt "$_dd" "-A OUTPUT -j $DNSCHAIN")
    while [ "${_dj:-0}" -gt 0 ]; do "$1" -w -t nat -D OUTPUT -j "$DNSCHAIN" 2>/dev/null || break; _dj=$((_dj - 1)); done
    _nat_has "$_dd" "$DNSCHAIN" && { "$1" -w -t nat -F "$DNSCHAIN" 2>/dev/null; "$1" -w -t nat -X "$DNSCHAIN" 2>/dev/null; }
    _dj=$(_nat_cnt "$_dd" "-A POSTROUTING -j $DNSSNAT")
    while [ "${_dj:-0}" -gt 0 ]; do "$1" -w -t nat -D POSTROUTING -j "$DNSSNAT" 2>/dev/null || break; _dj=$((_dj - 1)); done
    _nat_has "$_dd" "$DNSSNAT" && { "$1" -w -t nat -F "$DNSSNAT" 2>/dev/null; "$1" -w -t nat -X "$DNSSNAT" 2>/dev/null; }
    rm -f "$STATE/$3.want"
    unset _dd _dj
}
# _dns_to DUMP SERVER - the DNAT target of our rules as the kernel prints
# it: SERVER:53 for IPv4; for IPv6 the address in ip6tables' own short form
# ("FD00:0:0:0::53" in a config is listed as [fd00::53]:53 - compared with
# the config's text the chain would never be found right). Nothing when the
# rules do not all name one target, or an IPv4 one is not SERVER's.
_dns_to() {
    _ot=$(printf '%s\n' "$1" | sed -n "s/^-A $DNSCHAIN -o $IFACE .*--dport 53 .*--to-destination \\([^ ]*\\)\$/\\1/p" | sort -u)
    case "$2" in
        *:*) case "$_ot" in "["*"]:53") [ "$(printf '%s\n' "$_ot" | grep -c .)" = 1 ] || _ot="" ;; *) _ot="" ;; esac ;;
        *) [ "$_ot" = "$2:53" ] || _ot="" ;;
    esac
    echo "$_ot"; unset _ot
}
# dns_lan - LAN DNS through the tunnel: which interfaces and marks. Sets
#   DNS_LAN   key of the whole layout, empty = nothing to redirect
#   DNS_OIFS  interfaces of the captured networks (class default / tunnel)
#   DNS_OUT   netId marks of the networks that stay outside
#   DNS_CHK   netId marks of the networks Android is still checking
#   DNS_RES   resolvers of the endpoint lookup
#   DNS_ND DNS_NR  number of DNAT / RETURN rules the chain then has
# From $STATE/nets (nets_classify: "<netId> <table> <class> <number>"). A
# table without its name yet (netd adds it to rt_tables a moment after the
# network's rules, see tbl_num) is left out; the name is part of the key, so
# the chain is rebuilt once it is there.
dns_lan() {
    DNS_LAN=""; DNS_OIFS=""; DNS_OUT=""; DNS_CHK=""; DNS_RES=""; DNS_ND=2; DNS_NR=0
    [ -n "$DEF" ] || return 0
    _oifs=$IFS; IFS='
'
    for _l in $(tail -n +3 "$STATE/nets" 2>/dev/null); do
        IFS=' '; set -- $_l; IFS='
'
        case "$3" in
            default|tunnel)
                case "$2" in ""|"$IFACE"|*[!A-Za-z0-9._-]*) continue ;; *[!0-9]*) : ;; *) continue ;; esac
                case " $DNS_OIFS " in *" $2 "*) : ;; *) DNS_OIFS="$DNS_OIFS${DNS_OIFS:+ }$2"; DNS_ND=$((DNS_ND + 2)) ;; esac ;;
            outside) case "$1" in 0x*[!0-9a-fx]*) : ;; 0x?*) DNS_OUT="$DNS_OUT${DNS_OUT:+ }$1"; DNS_NR=$((DNS_NR + 1)) ;; esac ;;
            checking) case "$1" in 0x*[!0-9a-fx]*) : ;; 0x?*) DNS_CHK="$DNS_CHK${DNS_CHK:+ }$1"; DNS_NR=$((DNS_NR + 1)) ;; esac ;;
        esac
    done
    IFS=$_oifs
    unset _l _oifs
    [ -n "$DNS_OIFS" ] || return 0
    DNS_RES=$(resolvers_now)
    for _l in $DNS_RES; do DNS_NR=$((DNS_NR + 1)); done
    unset _l
    DNS_NR=$((DNS_NR + 2))    # loopback, the tunnel's DNS
    DNS_LAN="lan ${T_ADDR%/*}|$DNS_OIFS|$DNS_OUT|$DNS_CHK|$DNS_RES"
}
# _dns_ok DUMP TARGET [LAN] - our chain is exactly what it should be: one
# jump from OUTPUT, the two rules for wgs0 and nothing else - with LAN (the
# key dns_lan made) the DNS_ND DNAT rules, all to TARGET, the DNS_NR RETURN
# rules, and in POSTROUTING one jump to the two SNAT rules to the tunnel's
# own address; without it no SNAT chain. Counted as the kernel prints the
# rules (TARGET is read back from it), last words compared whole: a rule to
# 10.2.0.20 is not one to 10.2.0.2.
_dns_ok() {
    [ -n "$2" ] || return 1
    if [ -n "$3" ]; then _ow="1 $((DNS_ND + DNS_NR)) $DNS_ND 2 $DNS_NR 1 2 2"; else _ow="1 2 2 2 0 0 0 0"; fi
    _oh=$(printf '%s\n' "$1" | awk -v c="$DNSCHAIN" -v s="$DNSSNAT" -v o=" -o $IFACE " -v t="$2" -v a="${T_ADDR%/*}" '
        $1 != "-A" { next }
        NF == 4 && $3 == "-j" && $2 == "OUTPUT" && $4 == c { j++ }
        NF == 4 && $3 == "-j" && $2 == "POSTROUTING" && $4 == s { pj++ }
        $2 == c {
            n++
            if ($NF == "RETURN" && $(NF - 1) == "-j") r++
            else if ($NF == t && $(NF - 1) == "--to-destination" && $(NF - 2) == "DNAT" && index($0, " --dport 53 ") && index($0, " -o ")) { d++; if (index($0, o)) w++ }
        }
        $2 == s { sn++; if ($NF == a && $(NF - 1) == "--to-source" && $(NF - 2) == "SNAT" && index($0, " --dport 53 ") && index($0, o)) ss++ }
        END { print j + 0, n + 0, d + 0, w + 0, r + 0, pj + 0, sn + 0, ss + 0 }')
    [ "$_oh" = "$_ow" ]; _or=$?
    unset _ow _oh
    return $_or
}
# _dns_apply TOOL SERVER [LAN] - fills the chain; with LAN (dns_lan's key)
# the layout described above, the SNAT chain first
_dns_apply() {
    "$1" -w -t nat -N "$DNSCHAIN" 2>/dev/null || "$1" -w -t nat -F "$DNSCHAIN" 2>/dev/null
    _at=$(dns_dnat_to "$2")
    if [ -n "$3" ]; then
        _aa=${T_ADDR%/*}
        "$1" -w -t nat -N "$DNSSNAT" 2>/dev/null || "$1" -w -t nat -F "$DNSSNAT" 2>/dev/null
        for _p in udp tcp; do
            "$1" -w -t nat -A "$DNSSNAT" -o "$IFACE" -d "$2" -p "$_p" --dport 53 ! -s "$_aa" -j SNAT --to-source "$_aa" 2>/dev/null
        done
        "$1" -w -t nat -A POSTROUTING -j "$DNSSNAT" 2>/dev/null
        for _d in 127.0.0.0/8 "$2"; do
            "$1" -w -t nat -A "$DNSCHAIN" -d "$_d" -j RETURN 2>/dev/null
        done
        for _m in $DNS_OUT; do
            "$1" -w -t nat -A "$DNSCHAIN" -m mark --mark "$_m/0xffff" -j RETURN 2>/dev/null
        done
    fi
    for _p in udp tcp; do
        "$1" -w -t nat -A "$DNSCHAIN" -o "$IFACE" -p "$_p" --dport 53 -j DNAT --to-destination "$_at" 2>/dev/null
    done
    if [ -n "$3" ]; then
        for _m in $DNS_CHK; do
            "$1" -w -t nat -A "$DNSCHAIN" -m mark --mark "$_m/0xffff" -j RETURN 2>/dev/null
        done
        for _d in $DNS_RES; do
            "$1" -w -t nat -A "$DNSCHAIN" -d "$_d" -j RETURN 2>/dev/null
        done
        for _d in $DNS_OIFS; do
            for _p in udp tcp; do
                "$1" -w -t nat -A "$DNSCHAIN" -o "$_d" -p "$_p" --dport 53 -j DNAT --to-destination "$_at" 2>/dev/null
            done
        done
    fi
    unset _p _at _aa _d _m
}

# dns_ensure CAPTURE - sets ST_DNS (tunnel | dnscrypt | network), ST_DNS_SERVER
# and ST_DNS_LAN (the interfaces whose DNS goes to the tunnel's DNS as well)
dns_ensure() {
    _d4=$(_nat_dump "$IPTS" "$IPT")
    _w4=""; _w6=""; DNS_LAN=""
    if dnsc_dnat "$_d4"; then ST_DNS=dnscrypt
    else
        ST_DNS=network
        [ "$1" = 1 ] && [ -n "$T_DNS" ] && _w4=$T_DNS
        [ -n "$_w4" ] && [ "$V6ON" = 1 ] && [ -n "$T_DNS6" ] && _w6=$T_DNS6
        [ -n "$_w4" ] && [ "$S_LANDNS" = 1 ] && [ "$ST_STATE" = up ] && dns_lan
    fi
    _dns_sync "$IPT" "$IPTS" dns "$_w4" "$_d4" "" "$DNS_LAN" && [ -n "$_w4" ] && { ST_DNS=tunnel; ST_DNS_SERVER=$_w4; [ -n "$DNS_LAN" ] && ST_DNS_LAN=$DNS_OIFS; }
    if [ -n "$_w6" ] || [ -f "$STATE/dns6.want" ]; then
        _dns_sync "$IPT6" "$IPTS6" dns6 "$_w6" "$(_nat_dump "$IPTS6" "$IPT6")" " for IPv6" &&
            [ -n "$_w6" ] && [ "$ST_DNS" = tunnel ] && ST_DNS_SERVER="$ST_DNS_SERVER $_w6"
    fi
    unset _d4 _w4 _w6
}
# _dns_sync TOOL SAVE STATENAME SERVER DUMP LABEL [LAN] - 0 when the state is as wanted
_dns_sync() {
    _x=$1; _s=$2; _n=$3; _t=$4; _du=$5; _w=$6; _lk=$7
    if [ -z "$_t" ]; then
        rm -f "$STATE/$_n.bad"
        if [ -f "$STATE/$_n.want" ] || _nat_has "$_du" "$DNSCHAIN" || _nat_has "$_du" "$DNSSNAT"; then
            [ -f "$STATE/$_n.want" ] && wlog INFO "DNS$_w: left to $( [ "$ST_DNS" = dnscrypt ] && echo 'DNSCrypt Proxy' || echo 'the network')"
            _dns_del "$_x" "$_s" "$_n" "$_du"
        fi
        unset _x _s _n _t _du _w _lk; return 0
    fi
    # $STATE/<name>.want: the server as the config has it (with LAN DNS
    # through the tunnel: and "|" + dns_lan's key), then the DNAT target as
    # the kernel printed it when the chain was set up
    _k=$_t${_lk:+|$_lk}
    _old=$(sed -n 1p "$STATE/$_n.want" 2>/dev/null)
    if [ "$_old" = "$_k" ] && _dns_ok "$_du" "$(sed -n 2p "$STATE/$_n.want" 2>/dev/null)" "$_lk"; then unset _x _s _n _t _du _w _lk _k _old; return 0; fi
    # something is off (new server, other networks, or rules changed by
    # someone else): rebuild
    _dns_del "$_x" "$_s" "$_n" "$_du"
    _dns_apply "$_x" "$_t" "$_lk"
    "$_x" -w -t nat -A OUTPUT -j "$DNSCHAIN" 2>/dev/null
    _du=$(_nat_dump "$_s" "$_x"); _to=$(_dns_to "$_du" "$_t")
    if _dns_ok "$_du" "$_to" "$_lk"; then
        printf '%s\n%s\n' "$_k" "$_to" > "$STATE/$_n.want"; rm -f "$STATE/$_n.bad"
        if [ "$_old" = "$_k" ]; then wlog WARN "DNS$_w: the redirect to the tunnel's DNS was changed by someone else - repaired"
        elif [ "${_old%%|*}" != "$_t" ]; then wlog INFO "DNS: apps use the tunnel's DNS $_t$_w"; fi
        if [ "$_old" != "$_k" ]; then
            if [ -n "$_lk" ]; then wlog INFO "DNS: LAN DNS through the tunnel too - DNS leaving through $(echo "$DNS_OIFS" | sed 's/ /, /g') goes to $_t"
            else case "$_old" in "$_t|"*) wlog INFO "DNS: LAN DNS left to the network again - only DNS routed into the tunnel goes to $_t" ;; esac; fi
        fi
        _r=0
    else
        _dns_del "$_x" "$_s" "$_n"
        if [ "$_k" != "$(cat "$STATE/$_n.bad" 2>/dev/null)" ]; then
            echo "$_k" > "$STATE/$_n.bad"
            wlog WARN "DNS: could not send DNS$_w to $_t (${_x##*/}) - apps keep the network's resolvers"
        fi
        _r=1
    fi
    unset _x _s _n _t _du _w _lk _k _old _to
    return $_r
}

# boot guard (post-fs-data): block everything not bound to a network until the tunnel is up
boot_guard() {
    "$IP" route replace unreachable default metric 4096 table "$TABLE" 2>/dev/null
    "$IP" rule add pref 5020 iif lo fwmark 0x0/0x10000 lookup "$TABLE" 2>/dev/null
    "$IP" -6 rule add pref 5020 iif lo fwmark 0x0/0x10000 unreachable 2>/dev/null
}

iface_exists() { "$IP" link show "$IFACE" >/dev/null 2>&1; }

# type of the existing wgs0: the kernel's DEVTYPE (wireguard | amneziawg),
# else what we created it as (fake links in the harness have no DEVTYPE)
iface_kind() {
    _k=$(sed -n 's/^DEVTYPE=//p' "${WGS_SYSNET:-/sys/class/net}/$IFACE/uevent" 2>/dev/null)
    [ -n "$_k" ] || _k=$(cat "$STATE/iftype" 2>/dev/null)
    echo "$_k"; unset _k
}

anything_present() {
    iface_exists && return 0
    dns_present && return 0
    [ -n "$(rules_sig)" ]
}

teardown() {
    rules_del
    dns_del
    "$IP" route flush table "$TABLE" 2>/dev/null
    "$IP" -6 route flush table "$TABLE" 2>/dev/null
    "$IP" link del "$IFACE" 2>/dev/null
    rm -f "$STATE/dns.bad" "$STATE/dns6.bad"
    rm -f "$STATE/loaded" "$STATE/tunnel.info" "$STATE/rules.key" "$STATE/rules.sig" "$STATE/up_since" "$STATE/resolved_at" "$STATE/iftype" "$STATE/last_nets" "$STATE/rules.want" "$STATE/rules.bad" "$STATE/rules.fast" "$STATE/rules.dirty" "$STATE/live_rx" "$STATE/dead_at" "$STATE/live_probe_at" "$STATE/alive_at" "$STATE/live_paused"
}

# tunnel_ensure NAME - iface exists with the tunnel's type, carries NAME's
# keys/peer/address, is up. Sets T_ADDR T_EP T_EPIP T_EPHOST T_PORT T_MTU
# T_TYPE. Returns 1 with ERR set on a hard failure, 3 when a host-name
# endpoint cannot be resolved yet (retried).
tunnel_ensure() {
    name=$1; f=$(tun_file "$name"); ERR=""
    ck="$name $(cksum < "$f" 2>/dev/null | awk '{ print $1 }')"
    fresh=0
    if [ "$(cat "$STATE/loaded" 2>/dev/null)" != "$ck" ] || ! iface_exists; then
        tun_parse "$f" || { ERR="invalid_tunnel: $T_ERR"; return 1; }
        if [ "$T_TYPE" = amneziawg ] && [ "$FAKE_LINK" = 0 ] && ! awg_kernel_ok; then
            ERR=no_kernel_amneziawg; return 1
        fi
        # a link's type cannot change: WireGuard <-> AmneziaWG = new wgs0
        # (the unreachable route in table 51820 keeps the kill switch meanwhile)
        if iface_exists && [ "$(iface_kind)" != "$T_TYPE" ]; then
            "$IP" link del "$IFACE" 2>/dev/null
            wlog INFO "interface $IFACE recreated as $T_TYPE"
        fi
        if ! iface_exists; then
            "$IP" link add "$IFACE" type "$(link_type "$T_TYPE")" 2>/dev/null || {
                if [ "$T_TYPE" = amneziawg ]; then ERR=no_kernel_amneziawg; else ERR=no_kernel_wireguard; fi
                return 1; }
            echo "$T_TYPE" > "$STATE/iftype"
            rm -f "$STATE/loaded"; fresh=1
        fi
        if [ -n "$T_EPHOST" ]; then
            T_EPIP=$(resolve_host "$T_EPHOST") || { ERR=resolving; T_EPIP=""; routes_ensure; return 3; }
            wlog INFO "endpoint $T_EPHOST is $T_EPIP"
            mono_now > "$STATE/resolved_at"
        fi
        ep_rule "$T_EPIP"
        if [ "$FAKE_LINK" = 0 ]; then
            tool=$(wg_tool "$T_TYPE"); tn=${tool##*/}
            [ -x "$tool" ] || { ERR="${tn}_tool_missing"; return 1; }
            sc="$STATE/setconf.$$"
            tun_setconf "$f" "$sc" "$( [ -n "$T_EPHOST" ] && echo "$T_EPIP:$T_PORT")"
            "$tool" setconf "$IFACE" "$sc" 2>"$STATE/wg.err"; rc=$?
            rm -f "$sc"
            if [ "$rc" != 0 ]; then
                # wg/awg quote the offending line between ` and ' - that can be a key: cut it
                e=$(sed "s/\`[^']*'/\`…'/g" "$STATE/wg.err" 2>/dev/null | tr '\n' ' ')
                wlog ERROR "$tn setconf ($name): ${e:-no message}"
                rm -f "$STATE/wg.err"
                ERR="${tn}_setconf_failed"; return 1
            fi
            rm -f "$STATE/wg.err"
        fi
        "$IP" addr flush dev "$IFACE" 2>/dev/null
        "$IP" addr add "$T_ADDR" dev "$IFACE" 2>/dev/null
        info_save
        echo "$ck" > "$STATE/loaded"
        mono_now > "$STATE/up_since"
        live_reset   # liveness of the previous tunnel / interface does not count
        [ "$fresh" = 1 ] && wlog INFO "tunnel $name up (endpoint $T_EP, $T_TYPE)" || wlog INFO "tunnel $name loaded (endpoint $T_EP, $T_TYPE)"
    else
        { read -r T_ADDR; read -r T_EP; read -r T_EPIP; read -r T_MTU; read -r T_EPHOST; read -r T_PORT; read -r T_ADDR6; read -r T_V6; read -r T_TYPE; read -r T_DNS; read -r T_DNS6; } 2>/dev/null < "$STATE/tunnel.info"
        [ -n "$T_TYPE" ] || T_TYPE=wireguard
    fi
    case "$("$IP" link show "$IFACE" 2>/dev/null | head -n1)" in
        *",UP"*|*"<UP"*) : ;;
        *) "$IP" link set "$IFACE" mtu "${T_MTU:-1420}" up 2>/dev/null ;;
    esac
    routes_ensure
    v6_ensure
    return 0
}

# ep_rule ADDRESS - rule 5000 (the tunnel's own UDP around the tunnel) for
# the endpoint ADDRESS, set BEFORE wgs0 gets that endpoint: the first
# handshake leaves at setconf / link up / wg set, and without the rule it
# would be routed into wgs0 itself and dropped (retry after ~5 s). The rule
# of a previous endpoint goes at the same moment, so that address does not
# keep a way around the tunnel. rules_apply finds the result as it wants it.
ep_rule() {
    [ -n "$DEF" ] && [ -n "$1" ] || return 0
    "$IP" rule add pref 5000 iif lo to "$1/32" lookup "$DEFN" 2>/dev/null
    for _e in $("$IP" rule 2>/dev/null | awk '$1 == "5000:" { for (i = 1; i < NF; i++) if ($i == "to") print $(i + 1) }'); do
        [ "${_e%/32}" = "$1" ] || "$IP" rule del pref 5000 to "${_e%/32}/32" 2>/dev/null
    done
    unset _e
}

info_save() { printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$T_ADDR" "$T_EP" "$T_EPIP" "$T_MTU" "$T_EPHOST" "$T_PORT" "$T_ADDR6" "$T_V6" "$T_TYPE" "$T_DNS" "$T_DNS6" > "$STATE/tunnel.info"; }

# a host-name endpoint whose tunnel stopped answering: its address may have
# changed (dynamic DNS) - look it up again, at most once a minute
reresolve() {
    [ -n "$T_EPHOST" ] || return 0
    last=$(cat "$STATE/resolved_at" 2>/dev/null || echo 0)
    [ $(( $(mono_now) - last )) -ge 60 ] || return 0
    mono_now > "$STATE/resolved_at"
    new=$(resolve_host "$T_EPHOST") || return 0
    [ "$new" != "$T_EPIP" ] || return 0
    ep_rule "$new"
    if [ "$FAKE_LINK" = 0 ]; then
        tool=$(wg_tool "$T_TYPE")
        pk=$("$tool" show "$IFACE" peers 2>/dev/null | head -n1)
        [ -n "$pk" ] && "$tool" set "$IFACE" peer "$pk" endpoint "$new:$T_PORT" 2>/dev/null
    fi
    wlog INFO "endpoint $T_EPHOST moved: $T_EPIP -> $new"
    T_EPIP=$new; info_save
}

wg_handshake() {  # epoch of the latest handshake, 0 = never
    [ "$FAKE_LINK" = 0 ] || { cat "$STATE/fake_hs" 2>/dev/null || echo 0; return; }
    h=$("$(wg_tool "$T_TYPE")" show "$IFACE" latest-handshakes 2>/dev/null | awk '{ print $2; exit }')
    echo "${h:-0}"
}

wg_transfer() {
    ST_RX=""; ST_TX=""
    [ "$FAKE_LINK" = 0 ] || return 0
    set -- $("$(wg_tool "$T_TYPE")" show "$IFACE" transfer 2>/dev/null | awk '{ print $2, $3; exit }')
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
    test_stale
    detect_net
    prev=$(cat "$STATE/last_state" 2>/dev/null)
    ST_TUNNEL=$S_ACTIVE; ST_ENDPOINT=""; ST_HSAGE="-"; ST_DEF=$DEF; ST_ANDVPN=$ANDVPN
    ST_REASON=""; ST_RX=""; ST_TX=""; ST_EPHOST=""; ST_IPV6=""; V6ON=0; ST_PAUSELEFT=$(pause_left)
    ST_TYPE=""; T_TYPE=""; T_DNS=""; T_DNS6=""; ST_DNS=""; ST_DNS_SERVER=""; ST_DNS_LAN=""; ST_NETS=""; EXTRA=""; EXTRA_NAMES=""; ST_RECOVER=""; ST_RECOVER_FROM=""

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
        rm -f "$STATE/heal"   # off / paused / error: no recovery attempt
    else
        ST_PAUSELEFT=""
        shutting_down && return 2
        tunnel_ensure "$S_ACTIVE"; rc=$?
        ST_TYPE=$T_TYPE
        if [ "$rc" = 1 ]; then
            # at shutdown netd and the links go away - not a tunnel error
            shutting_down && return 2
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
                    # handshakes, but nothing answers through the tunnel (sh/recover.sh live_check)
                    if [ "$ST_STATE" = up ] && live_dead "$hs"; then ST_STATE=down; ST_REASON=no_answer; fi
                else
                    since=$(( $(mono_now) - $(cat "$STATE/up_since" 2>/dev/null || mono_now) ))
                    if [ "$since" -lt "$DOWN_AFTER" ]; then ST_STATE=handshaking; else ST_STATE=down; ST_REASON=no_handshake; fi
                fi
                [ -n "$DEF" ] || { [ "$ST_STATE" = up ] || ST_REASON=no_network; }
                if [ -n "$T_EPHOST" ] && [ -n "$DEF" ]; then
                    case "$ST_STATE" in down) reresolve; ST_ENDPOINT="$T_EPIP:$T_PORT" ;; esac
                fi
            fi
            # self-healing (sh/recover.sh): restarts, maybe another tunnel
            heal_tick
            heal_status
            ST_TYPE=$T_TYPE
            ST_ENDPOINT=""; [ -n "$T_EPIP" ] && ST_ENDPOINT="$T_EPIP:$T_PORT"
            ST_EPHOST=""; [ -n "$T_EPHOST" ] && ST_EPHOST=$T_EP
            capture=1
            [ "$S_KILLSWITCH" = 0 ] && [ "$ST_STATE" != up ] && capture=0
            nets_classify; ST_NETS=$NETS_ST
            [ "$capture" = 1 ] || EXTRA=""
            key="$DEFN|$NID|$LOCALTN|$T_EPIP|$capture|$(local_table)|$V6ON|$EXTRA|$(exempt_uids | tr -s ' ' ',')"
            oldkey=$(cat "$STATE/rules.key" 2>/dev/null)
            sig=$(rules_sig | cksum)
            if [ "$key" != "$oldkey" ] || [ "$sig" != "$(cat "$STATE/rules.sig" 2>/dev/null)" ] || [ -f "$STATE/rules.dirty" ]; then
                _fast=0; [ -f "$STATE/rules.dirty" ] && _fast=1
                shutting_down && return 2
                rules_apply "$capture"
                echo "$key" > "$STATE/rules.key"
                rules_sig | cksum > "$STATE/rules.sig"
                _also=""; [ -n "$EXTRA" ] && _also=", also through the tunnel: $EXTRA_NAMES"
                if [ -z "$oldkey" ]; then
                    wlog INFO "routing on: network ${DEF:-none} (netId ${NID:-none}), kill switch $S_KILLSWITCH, IPv6 $( [ "$V6ON" = 1 ] && echo 'through the tunnel' || echo blocked)$_also"
                elif [ "$key" != "$oldkey" ]; then
                    wlog INFO "routing updated: network ${DEF:-none} (netId ${NID:-none}), capture $capture, IPv6 $( [ "$V6ON" = 1 ] && echo tunnel || echo blocked)$_also"
                elif [ "$_fast" = 0 ]; then
                    wlog WARN "routing rules were changed by someone else - repaired"
                fi
            fi
            shutting_down && return 2
            dns_ensure "$capture"
            wg_transfer
            if [ "$V6ON" = 1 ]; then ST_IPV6=tunnel; elif v6_kernel_on; then ST_IPV6=blocked; else ST_IPV6=off; fi
        fi
    fi

    if [ -n "$ST_NETS" ] && [ "$ST_NETS" != "$(cat "$STATE/last_nets" 2>/dev/null)" ]; then
        echo "$ST_NETS" > "$STATE/last_nets"
        wlog INFO "networks: $(echo "$ST_NETS" | sed 's#/default# (default)#g; s#/tunnel# (through the tunnel)#g; s#/checking# (Android is checking it - through the tunnel meanwhile)#g; s#/outside# (stays outside: carrier service or no internet)#g; s#,#, #g')"
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

# self-healing: restarts, auto-switch, notification
. "$MODDIR/sh/recover.sh"
# speed test (ctl.sh test), its results order the auto-switch
. "$MODDIR/sh/speed.sh"
