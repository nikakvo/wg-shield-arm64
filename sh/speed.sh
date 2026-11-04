# WG Shield Arm64 - speed test (sourced after recover.sh)
#
# ctl.sh test <box> measures the tunnels of one Tunnels-tab box (a country
# code, "others" or "favorites"): ONE measurement per server address
# (endpoint IP). Proton runs several "servers" (BG-14, BG-18, ...) on one
# machine: same entry address, different exit addresses - they are as fast
# as each other and fail together, so one result counts for all of them.
#
# How (all temporary; the active tunnel and the kill switch are not touched):
#   wgt0      a second interface of that tunnel's type with that tunnel's
#             keys (one tunnel of the address), its address on it
#   4990      iif lo to <address>/32 lookup <default network table>
#             - wgt0's own UDP goes out directly, not into wgs0 / the kill
#             switch (and rp_filter's reverse lookup passes, like rule 5000)
#   51821     table: default dev wgt0
#   4991      iif lo oif wgt0 lookup 51821 - pings bound to wgt0 go there
# Measured: time from "interface up" to the first handshake (polled every
# 0.1 s, at most 5 s) and the average of 3 ping answers to 1.1.1.1 through
# wgt0 (pinged every 0.3 s for up to 10 s - answers may start late).
# Everything is removed after each address, on any exit (trap) and, if the
# test was killed, by the next tick (test_stale). The address of the tunnel
# that is on is measured through wgs0 (ping only, no second interface).
# A tunnel with the same private key as the one that is on is never loaded
# on wgt0 (one key on two interfaces confuses the server - the 2.2 laptop
# case); another tunnel of that address is used, else it is skipped.
# 4990/4991 are outside 50xx: the watchdog's rule check does not see them.
#
# Results: $DATA/speedtest (kept across reboots - the auto-switch order uses
# them), one line per address, the newest test wins:
#   address|handshake ms|ping ms|status|epoch|name,name,...
# status: ok | active (the tunnel that is on, ping only) | no_handshake |
#   no_answer (handshake, but no ping answer) | active_down | same_key |
#   no_kernel | no_address (host name not resolved) | failed (interface /
#   setconf refused, see Log)

TEST_IF=wgt0
TEST_TABLE=51821
TEST_FILE="$DATA/speedtest"
TEST_LOCK="$STATE/test.lock"
TEST_PROG="$STATE/test.progress"
TEST_HS_MAX=${WGS_TEST_HS_MAX:-50}          # x 0.1 s
TEST_TARGET="${WGS_TEST_TARGET:-1.1.1.1}"
TEST_PING_MAX=${WGS_TEST_PING_MAX:-10}     # s: answers may start late (see test_tunnel)

test_cleanup() {
    "$IP" link del "$TEST_IF" 2>/dev/null
    while "$IP" rule del pref 4990 2>/dev/null; do :; done
    while "$IP" rule del pref 4991 2>/dev/null; do :; done
    "$IP" route flush table "$TEST_TABLE" 2>/dev/null
    rm -f "$STATE"/testconf.*
}

test_lock_get() {
    mkdir -p "$STATE"
    if mkdir "$TEST_LOCK" 2>/dev/null; then echo $$ > "$TEST_LOCK/pid"; return 0; fi
    _stp=$(cat "$TEST_LOCK/pid" 2>/dev/null)
    [ -n "$_stp" ] && kill -0 "$_stp" 2>/dev/null && return 1
    test_cleanup; rm -rf "$TEST_LOCK"
    mkdir "$TEST_LOCK" 2>/dev/null || return 1
    echo $$ > "$TEST_LOCK/pid"
}
test_lock_release() { rm -rf "$TEST_LOCK" "$TEST_PROG"; }
test_running() { _stp=$(cat "$TEST_LOCK/pid" 2>/dev/null); [ -n "$_stp" ] && kill -0 "$_stp" 2>/dev/null; }

# a test that was killed (WebUI closed hard, phone reboot does it anyway):
# remove what it left. Called by every tick - only a file check normally.
test_stale() {
    [ -d "$TEST_LOCK" ] || return 0
    _stp=$(cat "$TEST_LOCK/pid" 2>/dev/null)
    [ -n "$_stp" ] || return 0               # just created, pid follows
    kill -0 "$_stp" 2>/dev/null && return 0
    test_cleanup; rm -rf "$TEST_LOCK" "$TEST_PROG"
    wlog WARN "speed test: a stopped test left its interface - removed"
}

# private key of a tunnel file (only compared, never printed)
tun_privkey() {
    tr -d '\r' < "$1" 2>/dev/null | awk '{ l = $0; sub(/^[ \t]+/, "", l); k = l; sub(/[ \t]*=.*/, "", k)
        if (tolower(k) == "privatekey") { sub(/^[^=]*=[ \t]*/, "", l); sub(/[ \t]+$/, "", l); print l; exit } }'
}

# tunnel NAME in box BOX? (FAVLIST = fav_names, read once)
test_in_box() {
    case "$1" in
        favorites) printf '%s\n' "$FAVLIST" | grep -qxF "$2" ;;
        others) [ -z "$(tun_country "$2")" ] ;;
        *) [ "$(tun_country "$2")" = "$1" ] ;;
    esac
}

# average of "rtt min/avg/max/mdev = a/b/c/d ms" (iputils) or
# "round-trip min/avg/max = a/b/c ms" (busybox), whole ms
ping_avg() { sed -n 's|.*= *[0-9.]*/\([0-9.]*\)/.*|\1|p' | head -n1 | cut -d. -f1; }

# test_tunnel NAME ADDRESS -> R_HS R_PING R_ST (tun_parse already done by the caller)
test_tunnel() {
    R_HS=""; R_PING=""; R_ST=failed
    test_cleanup
    "$IP" link add "$TEST_IF" type "$(link_type "$T_TYPE")" 2>/dev/null || { wlog WARN "speed test: cannot create $TEST_IF ($T_TYPE)"; return; }
    _stool=$(wg_tool "$T_TYPE")
    if [ "$FAKE_LINK" = 0 ]; then
        _ssc="$STATE/testconf.$$"
        tun_setconf "$(tun_file "$1")" "$_ssc" "$2:$T_PORT"
        "$_stool" setconf "$TEST_IF" "$_ssc" 2>"$STATE/testconf.err.$$"; _src=$?
        if [ "$_src" != 0 ]; then
            _se=$(sed "s/\`[^']*'/\`…'/g" "$STATE/testconf.err.$$" 2>/dev/null | tr '\n' ' ')
            wlog WARN "speed test: ${_stool##*/} setconf ($1): ${_se:-no message}"
            test_cleanup; return
        fi
        rm -f "$_ssc" "$STATE/testconf.err.$$"
    fi
    "$IP" addr add "$T_ADDR" dev "$TEST_IF" 2>/dev/null
    # its UDP goes out directly BEFORE the interface comes up (the first
    # handshake leaves the moment it is up)
    "$IP" rule add pref 4990 iif lo to "$2/32" lookup "$DEFN" 2>/dev/null
    _st0=$(mono_cs)
    "$IP" link set "$TEST_IF" mtu "${T_MTU:-1420}" up 2>/dev/null
    "$IP" route replace default dev "$TEST_IF" table "$TEST_TABLE" 2>/dev/null
    "$IP" rule add pref 4991 iif lo oif "$TEST_IF" lookup "$TEST_TABLE" 2>/dev/null
    _sn=0; _shs=0
    while [ "$_sn" -lt "$TEST_HS_MAX" ]; do
        if [ "$FAKE_LINK" = 0 ]; then
            _shs=$("$_stool" show "$TEST_IF" latest-handshakes 2>/dev/null | awk '{ print $2; exit }')
        else
            _shs=$(cat "$STATE/fake_test_hs" 2>/dev/null)
        fi
        [ "${_shs:-0}" -gt 0 ] 2>/dev/null && break
        sleep 0.1 2>/dev/null || sleep 1
        _sn=$((_sn + 1))
    done
    if [ "${_shs:-0}" -gt 0 ] 2>/dev/null; then
        R_HS=$(( ($(mono_cs) - _st0) * 10 ))
        # a server can take a few seconds before a key it has not seen for a
        # while carries traffic (seen on the phone: the first test of a box
        # got no answer within 3 s, the next one did) - keep pinging every
        # 0.3 s until 3 answers or TEST_PING_MAX s; the average counts only
        # the answers
        _spo=$("$PING" -c 3 -i 0.3 -w "$TEST_PING_MAX" -I "$TEST_IF" "$TEST_TARGET" 2>/dev/null)
        R_PING=$(printf '%s\n' "$_spo" | ping_avg)
        _ssq=$(printf '%s\n' "$_spo" | sed -n 's/.*icmp_seq=\([0-9]*\).*/\1/p' | head -n1)
        if [ -n "$R_PING" ]; then
            R_ST=ok
            # how long the first answer took (seq 1 = at once)
            [ -n "$_ssq" ] && [ "$_ssq" -gt 1 ] 2>/dev/null && wlog INFO "speed test: $2 - first answer after about $(( (_ssq - 1) * 3 / 10 )).$(( (_ssq - 1) * 3 % 10 )) s"
        else
            R_ST=no_answer
            wlog INFO "speed test: $2 - handshake, but no answer within $TEST_PING_MAX s ($(printf '%s\n' "$_spo" | grep -m1 'transmitted' || echo 'ping gave no summary'))"
        fi
        unset _spo _ssq
    else
        R_ST=no_handshake
    fi
    test_cleanup
    unset _stool _ssc _src _se _st0 _sn _shs
}

# the address of the tunnel that is on: through wgs0
test_active() {
    R_HS=""; R_PING=$("$PING" -c 3 -i 0.2 -w 3 -I "$IFACE" "$TEST_TARGET" 2>/dev/null | ping_avg)
    if [ -n "$R_PING" ]; then R_ST=active; else R_ST=no_answer; fi
}

# test_run BOX - prints r= lines, writes $TEST_FILE. Caller holds the test lock.
test_run() {
    _sbox=$1
    settings_load; detect_net
    [ -n "$DEF" ] || { echo "ok=0"; echo "error=no network - connect to Wi-Fi or mobile data first"; return 1; }
    FAVLIST=$(fav_names)
    # the tunnel that is on (its address, its key, does it carry traffic)
    _sst=$(sed -n 's/^state=//p' "$STATE/status" 2>/dev/null)
    _saa=""; _sak=""
    if [ -n "$S_ACTIVE" ] && iface_exists; then
        _saa=$(sed -n '3p' "$STATE/tunnel.info" 2>/dev/null)
        _sak=$(tun_privkey "$(tun_file "$S_ACTIVE")")
    fi
    # group the box's tunnels by address: "address name" lines
    _spairs=""; _scnt=0
    for _stn in $(tun_names); do
        test_in_box "$_sbox" "$_stn" || continue
        tun_parse "$(tun_file "$_stn")" >/dev/null 2>&1 || continue
        _scnt=$((_scnt + 1))
        _sa=$T_EPIP
        if [ -n "$T_EPHOST" ]; then
            # rule 5001 is one of ours (50xx): only under the watchdog's lock
            if lock_get 20; then _sa=$(resolve_host "$T_EPHOST") || _sa="host:$T_EPHOST"; lock_release; else _sa="host:$T_EPHOST"; fi
        fi
        [ -n "$_sa" ] || _sa="host:${T_EP%:*}"
        _spairs="$_spairs$_sa $_stn
"
    done
    [ "$_scnt" -gt 0 ] || { echo "ok=0"; echo "error=no tunnels in $_sbox"; return 1; }
    _sas=$(printf '%s' "$_spairs" | awk 'NF { if (!s[$1]++) print $1 }')
    _stot=$(printf '%s\n' "$_sas" | grep -c .)
    _snow=$(epoch_now); _si=0; _sres=""
    wlog INFO "speed test: $_sbox - $_scnt tunnels on $_stot server addresses"
    for _sa in $_sas; do
        _si=$((_si + 1))
        echo "$_sbox|$_si|$_stot|$_sa" > "$TEST_PROG"
        _snames=$(printf '%s' "$_spairs" | awk -v a="$_sa" '$1 == a { print $2 }')
        _slist=$(echo $_snames | tr ' ' ',')
        R_HS=""; R_PING=""
        case "$_sa" in
            host:*) R_ST=no_address ;;
            *)
                if [ -n "$_saa" ] && [ "$_sa" = "$_saa" ]; then
                    if [ "$_sst" = up ]; then test_active; else R_HS=""; R_PING=""; R_ST=active_down; fi
                else
                    R_ST=same_key; _spick=""
                    for _stn in $_snames; do
                        tun_parse "$(tun_file "$_stn")" >/dev/null 2>&1 || continue
                        if [ "$T_TYPE" = amneziawg ] && [ "$FAKE_LINK" = 0 ] && ! awg_kernel_ok; then R_ST=no_kernel; continue; fi
                        if [ -n "$_sak" ] && [ "$(tun_privkey "$(tun_file "$_stn")")" = "$_sak" ]; then continue; fi
                        _spick=$_stn; break
                    done
                    [ -n "$_spick" ] && test_tunnel "$_spick" "$_sa"
                fi ;;
        esac
        _sres="$_sres$_sa|$R_HS|$R_PING|$R_ST|$_snow|$_slist
"
        echo "r=$_sa|$R_HS|$R_PING|$_slist|$R_ST"
        wlog INFO "speed test: $_sa ($_slist) - $R_ST${R_PING:+, ping $R_PING ms}${R_HS:+, handshake $R_HS ms}"
    done
    # merge: this run replaces the lines of its addresses and of its tunnels
    _snew=$(printf '%s' "$_sres" | cut -d'|' -f1)
    _stun=$(printf '%s' "$_spairs" | awk 'NF { print $2 }')
    {
        [ -f "$TEST_FILE" ] && awk -F'|' -v A="$(echo $_snew)" -v T="$(echo $_stun)" '
            BEGIN { OFS = "|"; n = split(A, a, " "); for (i = 1; i <= n; i++) da[a[i]] = 1
                    n = split(T, t, " "); for (i = 1; i <= n; i++) dt[t[i]] = 1 }
            NF >= 6 && !($1 in da) {
                m = split($6, x, ","); keep = ""
                for (i = 1; i <= m; i++) if (!(x[i] in dt)) keep = keep (keep == "" ? "" : ",") x[i]
                if (keep != "") { $6 = keep; print }
            }' "$TEST_FILE"
        printf '%s' "$_sres"
    } > "$TEST_FILE.tmp.$$" && chmod 600 "$TEST_FILE.tmp.$$" && mv -f "$TEST_FILE.tmp.$$" "$TEST_FILE"
    echo "ok=1"; echo "box=$_sbox"; echo "epoch=$_snow"; echo "addresses=$_stot"; echo "tunnels=$_scnt"
    unset _sbox _sst _saa _sak _spairs _scnt _sa _sas _stot _snow _si _sres _snames _slist _spick _snew _stun _stn
}

# poll rows: s=address|handshake ms|ping ms|status|age s|names
test_rows() {
    [ -f "$TEST_FILE" ] || return 0
    awk -F'|' -v now="$(epoch_now)" 'NF >= 6 { print "s=" $1 "|" $2 "|" $3 "|" $4 "|" (now - $5) "|" $6 }' "$TEST_FILE"
}

# auto-switch: rank of a tunnel by its last test - ping ms when it answered,
# 50000 untested, 90000 tested and failed
test_rank() {
    [ -f "$TEST_FILE" ] || { echo 50000; return; }
    awk -F'|' -v n="$1" '
        NF >= 6 { m = split($6, x, ","); for (i = 1; i <= m; i++) if (x[i] == n) {
            if (($4 == "ok" || $4 == "active") && $3 != "") r = $3 + 0; else r = 90000 } }
        END { print (r == "" ? 50000 : r) }' "$TEST_FILE"
}
