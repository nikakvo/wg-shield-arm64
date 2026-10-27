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
dnsc_ipv4_only() {
    [ -d "$DNSC_MOD" ] && [ ! -f "$DNSC_MOD/disable" ] && [ ! -f "$DNSC_MOD/remove" ] || return 1
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

# resolve_host NAME -> first IPv4. Plain DNS to Quad9, sent around the tunnel
# for a moment (rule 5001): the tunnel is not up yet, and these are the
# resolvers DNSCrypt Proxy lets root query directly (its bootstrap exemption).
RESOLVERS="9.9.9.9 149.112.112.112"
resolve_host() {
    [ -n "$DEF" ] || return 1
    for srv in $RESOLVERS; do
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
    [ -n "$(rules_sig)" ]
}

teardown() {
    rules_del
    "$IP" route flush table "$TABLE" 2>/dev/null
    "$IP" -6 route flush table "$TABLE" 2>/dev/null
    "$IP" link del "$IFACE" 2>/dev/null
    rm -f "$STATE/loaded" "$STATE/tunnel.info" "$STATE/rules.key" "$STATE/rules.sig" "$STATE/up_since" "$STATE/resolved_at" "$STATE/iftype" "$STATE/last_nets" "$STATE/rules.want" "$STATE/rules.bad" "$STATE/rules.fast" "$STATE/rules.dirty"
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
        [ "$fresh" = 1 ] && wlog INFO "tunnel $name up (endpoint $T_EP, $T_TYPE)" || wlog INFO "tunnel $name loaded (endpoint $T_EP, $T_TYPE)"
    else
        { read -r T_ADDR; read -r T_EP; read -r T_EPIP; read -r T_MTU; read -r T_EPHOST; read -r T_PORT; read -r T_ADDR6; read -r T_V6; read -r T_TYPE; } 2>/dev/null < "$STATE/tunnel.info"
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

info_save() { printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$T_ADDR" "$T_EP" "$T_EPIP" "$T_MTU" "$T_EPHOST" "$T_PORT" "$T_ADDR6" "$T_V6" "$T_TYPE" > "$STATE/tunnel.info"; }

# a host-name endpoint whose tunnel stopped answering: its address may have
# changed (dynamic DNS) - look it up again, at most once a minute
reresolve() {
    [ -n "$T_EPHOST" ] || return 0
    last=$(cat "$STATE/resolved_at" 2>/dev/null || echo 0)
    [ $(( $(mono_now) - last )) -ge 60 ] || return 0
    mono_now > "$STATE/resolved_at"
    new=$(resolve_host "$T_EPHOST") || return 0
    [ "$new" != "$T_EPIP" ] || return 0
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
    detect_net
    prev=$(cat "$STATE/last_state" 2>/dev/null)
    ST_TUNNEL=$S_ACTIVE; ST_ENDPOINT=""; ST_HSAGE="-"; ST_DEF=$DEF; ST_ANDVPN=$ANDVPN
    ST_REASON=""; ST_RX=""; ST_TX=""; ST_EPHOST=""; ST_IPV6=""; V6ON=0; ST_PAUSELEFT=$(pause_left)
    ST_TYPE=""; T_TYPE=""; ST_NETS=""; EXTRA=""; EXTRA_NAMES=""

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
