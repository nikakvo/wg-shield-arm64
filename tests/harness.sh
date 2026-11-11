#!/usr/bin/env bash
# WG Shield Arm64 - offline test harness (Linux PC, no phone, no root).
#
# Runs the module's own scripts inside a private user + network namespace
# (unshare -n --map-auto, else -rn: uid 0 and CAP_NET_ADMIN there, nothing
# outside is touched).
# netd is imitated with its rules (16000 explicit network, 31000 default
# network) and a table per network; the tunnel link is a veth
# (WGS_LINKTYPE), the handshake comes from $STATE/fake_hs. Android tools
# (getprop, dumpsys, pm, ping, su, cmd) are small fakes.
#
#   bash tests/harness.sh            run every case
#   bash tests/harness.sh -k NAME    run the cases whose name contains NAME
#   WGS_TEST_BB=/path/busybox bash tests/harness.sh   the same with busybox ash
#   WGS_TEST_SH=/path/mksh bash tests/harness.sh      the same with mksh (the
#                                     WebUI's shell; host tools for applets)
#
# Scratch goes to tests/.run (ext4 next to the repo), removed at the start.
set -u
REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
if [ "${WGS_IN_NS:-}" != 1 ]; then
    command -v unshare >/dev/null || { echo "unshare (util-linux) is needed"; exit 2; }
    command -v ip >/dev/null || { echo "ip (iproute2) is needed"; exit 2; }
    # --map-auto maps the subuid range too: netd-style uidrange rules (5014)
    # need the uids to exist in the namespace; without it they are refused
    if unshare -n --map-auto --map-root-user true 2>/dev/null; then
        exec env WGS_IN_NS=1 WGS_UIDS=1 unshare -n --map-auto --map-root-user bash "$0" "$@"
    fi
    exec env WGS_IN_NS=1 unshare -rn bash "$0" "$@"
fi
FILTER=""; [ "${1:-}" = -k ] && FILTER=${2:-}
# WGS_TEST_BB=/path/to/busybox: run the scripts with busybox ash and its
# applets (unzip, gzip, ...) like KernelSU does; default: bash + host tools
TSH=$(command -v bash)
[ -n "${WGS_TEST_BB:-}" ] && TSH="$WGS_TEST_BB sh"
[ -n "${WGS_TEST_SH:-}" ] && TSH=$WGS_TEST_SH

RUN="$REPO/tests/.run"
rm -rf "$RUN"; mkdir -p "$RUN"
FAKES="$RUN/fakes"; mkdir -p "$FAKES"

# ---- fakes ---------------------------------------------------------------------
cat > "$FAKES/getprop" <<'EOF'
#!/bin/sh
case "$1" in sys.boot_completed) echo 1 ;; debug.tracing.screen_state) echo 2 ;; esac
EOF
# dumpsys connectivity: one line per network in $RUN/networks ("<netId> <caps>")
cat > "$FAKES/dumpsys" <<EOF
#!/bin/sh
[ "\$1" = connectivity ] || exit 0
while read -r n c; do echo "  NetworkAgentInfo{network{\$n}  handle{1}  ni{X CONNECTED}  nc{[ Transports: WIFI Capabilities: \$c LinkUpBandwidth>=1Kbps ]}"; done < "$RUN/networks"
EOF
echo "100 INTERNET&NOT_RESTRICTED&TRUSTED&VALIDATED" > "$RUN/networks"
printf '#!/bin/sh\necho "package:com.android.captiveportallogin uid:10050"\n' > "$FAKES/pm"
printf '#!/bin/sh\nexit 1\n' > "$FAKES/ping"
printf '#!/bin/sh\nexit 0\n' > "$FAKES/su"
printf '#!/bin/sh\nexit 0\n' > "$FAKES/cmd"
# iptables: the rules as "-A CHAIN ..." lines in $WGS_IPT_DIR/<table>
# (exact text match for -C / -D, chains with -N; enough for the DNS chain)
cat > "$FAKES/iptables" <<'EOF'
#!/bin/sh
[ "$1" = -w ] && shift
t=filter; [ "$1" = -t ] && { t=$2; shift 2; }
mkdir -p "$WGS_IPT_DIR"; f="$WGS_IPT_DIR/$t"; touch "$f"
op=$1; ch=$2; shift 2; r="-A $ch $*"; r=${r% }
has() { grep -qx -- "-N $ch" "$f"; }
case "$op" in
    -N) has && exit 1; echo "-N $ch" >> "$f" ;;
    -F) has || exit 1; grep -v -- "^-A $ch " "$f" > "$f.n"; mv "$f.n" "$f" ;;
    -X) has || exit 1; grep -q -- "^-A $ch " "$f" && exit 1; grep -q -- "-j $ch\$" "$f" && exit 1
        grep -vx -- "-N $ch" "$f" > "$f.n"; mv "$f.n" "$f" ;;
    -A) [ "$ch" = OUTPUT ] || [ "$ch" = POSTROUTING ] || has || exit 1; echo "$r" >> "$f" ;;
    -C) grep -qxF -- "$r" "$f" ;;
    -D) grep -qxF -- "$r" "$f" || exit 1
        awk -v l="$r" '!d && $0 == l { d = 1; next } { print }' "$f" > "$f.n"; mv "$f.n" "$f" ;;
    -S) has || exit 1; grep -- "^-A $ch " "$f" ;;
    *) exit 2 ;;
esac
EOF
# ip6tables: the same, in $WGS_IPT_DIR/v6
printf '#!/bin/sh\nWGS_IPT_DIR="$WGS_IPT_DIR/v6" exec "%s" "$@"\n' "$FAKES/iptables" > "$FAKES/ip6tables"
# iptables-save -t TABLE: chains as ":NAME - [0:0]", then the rules
cat > "$FAKES/iptables-save" <<'XEOF'
#!/bin/sh
t=filter; [ "$1" = -t ] && t=$2
f="$WGS_IPT_DIR/$t"
echo "*$t"
[ -f "$f" ] && { sed -n 's/^-N \(.*\)/:\1 - [0:0]/p' "$f"; grep -- '^-A ' "$f"; }
echo COMMIT
XEOF
printf '#!/bin/sh\nWGS_IPT_DIR="$WGS_IPT_DIR/v6" exec "%s" "$@"\n' "$FAKES/iptables-save" > "$FAKES/ip6tables-save"
# ip as on the phone: Android's ip reads netd's rt_tables, so rule listings
# say "lookup wlan0"; the host's ip prints the number. Used by the DNS cases
# (the redirect matches the interface named after the table).
REALIP=$(command -v ip)
cat > "$FAKES/ipn" <<EOF
#!/bin/sh
case "\$*" in
    *rule*add*|*rule*del*|*-batch*|*monitor*) exec "$REALIP" "\$@" ;;
    *rule*) o=\$("$REALIP" "\$@"); rc=\$?
        printf '%s\\n' "\$o" | awk 'NR == FNR { n[\$1] = \$2; next } { for (i = 1; i < NF; i++) if (\$i == "lookup" && (\$(i + 1) in n)) \$(i + 1) = n[\$(i + 1)]; print }' "\$WGS_RT_TABLES" -
        exit \$rc ;;
    *) exec "$REALIP" "\$@" ;;
esac
EOF
# ip that notes, at the moments wgs0 would send its first handshake (setconf
# comes right before "addr flush"; a new link: "link set ... up"), which
# endpoints rule 5000 sends around the tunnel
cat > "$FAKES/ipo" <<EOF
#!/bin/sh
case "\$*" in
    "addr flush dev wgs0"|"link set wgs0 mtu "*" up") echo "\${1}: \$("$REALIP" rule | sed -n 's/^5000:.* to \([0-9.]*\) .*/\1/p' | tr '\n' ' ')" >> "\$WGS_IPLOG" ;;
esac
exec "$REALIP" "\$@"
EOF
chmod 755 "$FAKES"/*

# ---- module copy (module_desc rewrites module.prop: never the repo's) ----------
MOD="$RUN/module"
mkdir -p "$MOD"
cp -r "$REPO"/sh "$REPO"/*.sh "$REPO"/module.prop "$MOD"/

export WGS_MODDIR="$MOD" WGS_DATA="$RUN/data" WGS_ADB="$RUN/adb" WGS_MODULES="$RUN/adb/modules"
export WGS_BACKUP_ROOT="$RUN/sdcard/wg-shield" WGS_DL="$RUN/sdcard/Download"
export WGS_IP="$(command -v ip)" WGS_BB="${WGS_TEST_BB:-$RUN/no-busybox}" WGS_RT_TABLES="$RUN/rt_tables"
export WGS_GETPROP="$FAKES/getprop" WGS_DUMPSYS="$FAKES/dumpsys" WGS_PM="$FAKES/pm"
export WGS_PING="$FAKES/ping" WGS_SU="$FAKES/su" WGS_CMD="$FAKES/cmd"
export WGS_LINKTYPE=veth WGS_PROC6="$RUN/proc6" WGS_SYSNET="$RUN/sysnet"
export WGS_SH="$TSH" WGS_HEAL_WAIT=1
export WGS_IPT="$FAKES/iptables" WGS_IPT6="$FAKES/ip6tables" WGS_IPTS="$FAKES/iptables-save" WGS_IPTS6="$FAKES/ip6tables-save" WGS_IPT_DIR="$RUN/ipt"
STATE="$WGS_DATA/state"
mkdir -p "$WGS_MODULES" "$WGS_DL" "$WGS_PROC6/all"
echo 1 > "$WGS_PROC6/all/disable_ipv6"          # no IPv6 on the fake phone
printf '%s\n' "97 local_network" "1028 wlan0" > "$WGS_RT_TABLES"

# ---- the fake network: wlan0 (netId 100 = 0x64), netd's rules ------------------
ip link set lo up
ip link add wlan0 type veth peer name wlan0p && ip link set wlan0p up && ip link set wlan0 up
ip addr add 192.168.1.50/24 dev wlan0
ip route add 192.168.1.0/24 dev wlan0 table 1028
ip route add default via 192.168.1.1 dev wlan0 table 1028
ip rule add pref 16000 fwmark 0x10064/0x1ffff iif lo lookup 1028
ip rule add pref 31000 fwmark 0x0/0xffff iif lo lookup 1028
# netd drops what no rule took (unreachable at the end of its chain)
ip rule add pref 32000 unreachable

ctl() { $TSH "$MOD/ctl.sh" "$@"; }
kv() { sed -n "s/^$1=\\([0-9]*\\)\$/\\1/p"; }   # numeric key=value only
st() { sed -n "s/^$1=//p" "$STATE/status" 2>/dev/null; }
# where an app's unbound socket goes: "wgs0", "wlan0" or "blocked"
route_of() {
    r=$(ip route get 1.1.1.1 2>&1 | head -n1)
    case "$r" in *"dev wgs0"*) echo wgs0 ;; *"dev wlan0"*) echo wlan0 ;; *) echo blocked ;; esac
}
conf() {  # conf FILE ENDPOINT
    cat > "$1" <<EOF
[Interface]
PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
PublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=
AllowedIPs = 0.0.0.0/0
Endpoint = $2
EOF
}
reset_state() {
    ctl down >/dev/null 2>&1
    ctl removeall >/dev/null 2>&1
    rm -rf "$WGS_DATA"
}

PASS=0; FAILN=0
check() {  # check DESCRIPTION EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "  ok   $1"
    else FAILN=$((FAILN + 1)); echo "  FAIL $1: expected '$2', got '$3'"; fi
}
want() { [ -z "$FILTER" ] || case "$1" in *"$FILTER"*) return 0 ;; *) return 1 ;; esac; }

# ---- cases -----------------------------------------------------------------------
if want basic; then
    echo "basic: import, up, handshake, kill switch, down"
    reset_state
    conf "$WGS_DL/wg-BG-1.conf" 203.0.113.10:51820
    check "import" 1 "$(ctl import wg-BG-1.conf | kv imported)"
    check "direct before up" wlan0 "$(route_of)"
    ctl up wg-BG-1 >/dev/null
    check "state after up (no handshake yet)" handshaking "$(st state)"
    check "traffic into the tunnel" wgs0 "$(route_of)"
    date +%s > "$STATE/fake_hs"
    ctl status >/dev/null
    check "state with a handshake" up "$(st state)"
    ip link set wgs0 down
    ip route del default dev wgs0 table 51820 2>/dev/null
    check "kill switch backstop while wgs0 has no route" blocked "$(route_of)"
    ctl status >/dev/null
    check "routes repaired by a tick" wgs0 "$(route_of)"
    ctl down >/dev/null
    check "state after down" off "$(st state)"
    check "direct after down" wlan0 "$(route_of)"
fi

if want endpoint_rule; then
    echo "endpoint_rule: rule 5000 knows the new endpoint before the first handshake"
    reset_state
    export WGS_IPLOG="$RUN/iplog"; rm -f "$WGS_IPLOG"
    conf "$WGS_DL/wg-SE-1.conf" 203.0.113.71:51820
    conf "$WGS_DL/wg-SE-2.conf" 203.0.113.72:51820
    conf "$WGS_DL/wg-SE-3.conf" 203.0.113.73:51820
    for n in wg-SE-1 wg-SE-2 wg-SE-3; do ctl import "$n.conf" >/dev/null; done
    WGS_IP="$FAKES/ipo" ctl up wg-SE-1 >/dev/null
    check "first tunnel: new link comes up with its endpoint rule" "link: 203.0.113.71 " "$(grep '^link' "$WGS_IPLOG" | tail -n 1)"
    rm -f "$WGS_IPLOG"
    WGS_IP="$FAKES/ipo" ctl up wg-SE-2 >/dev/null
    check "switch: the new endpoint's rule, the old one gone, before setconf" "addr: 203.0.113.72 " "$(grep '^addr' "$WGS_IPLOG" | tail -n 1)"
    check "switch: one endpoint rule afterwards" "1 1" "$(ip rule | grep -c '^5000:') $(ip rule | grep -c '^5000:.*to 203.0.113.72 ')"
    rm -f "$WGS_IPLOG"
    ip link del wgs0                         # recovery: wgs0 is created again
    WGS_IP="$FAKES/ipo" ctl up wg-SE-3 >/dev/null
    check "new link on another endpoint: its rule first" "link: 203.0.113.73 " "$(grep '^link' "$WGS_IPLOG" | tail -n 1)"
    ctl down >/dev/null
    check "down: no endpoint rule left" 0 "$(ip rule | grep -c '^5000:')"
    unset WGS_IPLOG
fi

if want status_backslash; then
    echo "status_backslash: a backslash in a status value is written as it is"
    reset_state
    conf "$WGS_DL/wg-AT-1.conf" 203.0.113.81:51820
    ctl import wg-AT-1.conf >/dev/null
    ctl up wg-AT-1 >/dev/null
    # the tunnel file edited by root afterwards: the error quotes the raw Endpoint
    sed -i 's#^Endpoint = .*#Endpoint = vpn\\cx.example:51820#' "$WGS_DATA/tunnels/wg-AT-1.conf"
    ctl status >/dev/null
    check "reason kept with its backslash" "invalid_tunnel: Endpoint must be an IPv4 address or a host name (got 'vpn\\cx.example:51820')" "$(st reason)"
    check "keys after it still written" wg-AT-1 "$(st tunnel)"
    ctl down >/dev/null
fi

if want killswitch_off; then
    echo "killswitch_off: down tunnel goes direct"
    reset_state
    conf "$WGS_DL/wg-NL-1.conf" 203.0.113.11:51820
    ctl import wg-NL-1.conf >/dev/null
    ctl set killswitch 0 >/dev/null
    ctl up wg-NL-1 >/dev/null
    check "handshaking + kill switch off = direct" wlan0 "$(route_of)"
    ctl set killswitch 1 >/dev/null
    check "kill switch on = through the tunnel" wgs0 "$(route_of)"
fi

if want validate; then
    echo "validate: endpoint and address checks"
    reset_state
    for ep in 203.0.113.1:0 203.0.113.1:65536 203.0.113.1:99999 999.1.1.1:51820 1.2.3:51820 1.2.3.4.5:51820 010.1.1.1:51820 203.0.113.01:51820; do
        conf "$WGS_DL/bad.conf" "$ep"
        check "endpoint $ep refused" 0 "$(ctl import bad.conf | kv imported)"
    done
    conf "$WGS_DL/ok.conf" 203.0.113.1:65535
    check "endpoint port 65535 accepted" 1 "$(ctl import ok.conf | kv imported)"
    conf "$WGS_DL/host.conf" vpn.example.com:51820
    check "host name endpoint accepted" 1 "$(ctl import host.conf | kv imported)"
    conf "$WGS_DL/addr.conf" 203.0.113.1:51820
    sed -i 's#^Address = .*#Address = 10.2.0.300/32#' "$WGS_DL/addr.conf"
    check "address 10.2.0.300 refused" 0 "$(ctl import addr.conf | kv imported)"
    sed -i 's#^Address = .*#Address = 10.2.0.2/33#' "$WGS_DL/addr.conf"
    check "address prefix /33 refused" 0 "$(ctl import addr.conf | kv imported)"
    sed -i 's#^Address = .*#Address = 10.2.0.2/24, fd00::2/128#' "$WGS_DL/addr.conf"
    check "address /24 + IPv6 accepted" 1 "$(ctl import addr.conf | kv imported)"
    sed -i 's#^Address = .*#Address = 10.2.0.02/32#' "$WGS_DL/addr.conf"
    check "address 10.2.0.02 (leading zero) refused" 0 "$(ctl import addr.conf | kv imported)"
    conf "$WGS_DL/zero.conf" 203.0.113.0:51820
    sed -i 's#^Address = .*#Address = 10.0.0.2/32#' "$WGS_DL/zero.conf"
    check "octets that are 0 accepted" 1 "$(ctl import zero.conf | kv imported)"
fi

if want zipslip; then
    echo "zipslip: an export zip cannot write outside the import folder"
    reset_state
    if command -v python3 >/dev/null; then
        conf "$RUN/inner.conf" 203.0.113.12:51820
        python3 -I - "$WGS_DL/evil.zip" "$RUN/inner.conf" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.write(sys.argv[2], "../../../../escaped.conf")
    z.write(sys.argv[2], "a/../../../../mid.conf")
EOF
        ctl import evil.zip >/dev/null 2>&1
        check "nothing written outside tunnels/" "" "$(find "$RUN" \( -name escaped.conf -o -name mid.conf \) -not -path "$WGS_DATA/tunnels/*")"
    else
        echo "  skip (python3 missing)"
    fi
fi

if want zipnames; then
    echo "zipnames: zip entries with spaces are imported and restored"
    reset_state
    if command -v python3 >/dev/null; then
        conf "$RUN/inner.conf" 203.0.113.16:51820
        python3 -I - "$WGS_DL/spaces.zip" "$RUN/inner.conf" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.write(sys.argv[2], "my vpn.conf")
    z.write(sys.argv[2], "dir with space/NL *.conf")
EOF
        out=$(ctl import spaces.zip 2>&1)
        check "both entries imported" 2 "$(echo "$out" | kv imported)"
        check "name with a space sanitized" "yes yes" "$([ -f "$WGS_DATA/tunnels/my_vpn.conf" ] && echo yes || echo no) $([ -f "$WGS_DATA/tunnels/NL__.conf" ] && echo yes || echo no)"
        ctl removeall >/dev/null
        mkdir -p "$WGS_BACKUP_ROOT"; cp "$WGS_DL/spaces.zip" "$WGS_BACKUP_ROOT/wg-shield-backup.zip"
        out=$(ctl restore 2>&1)
        check "restore: both entries imported" 2 "$(echo "$out" | kv imported)"
        rm -f "$WGS_BACKUP_ROOT/wg-shield-backup.zip" "$WGS_DL/spaces.zip"
    else
        echo "  skip (python3 missing)"
    fi
fi

if want lock; then
    echo "lock: settings changes wait for the watchdog's lock"
    reset_state
    conf "$WGS_DL/wg-DE-1.conf" 203.0.113.13:51820
    ctl import wg-DE-1.conf >/dev/null
    ctl up wg-DE-1 >/dev/null
    # a tick in progress: the lock is held by a live process
    sleep 30 & holder=$!
    mkdir "$STATE/lock" && echo "$holder" > "$STATE/lock/pid"
    ctl down >/dev/null 2>&1 & c=$!
    sleep 2
    check "settings untouched while the lock is held" wg-DE-1 "$(sed -n 's/^ACTIVE=//p' "$WGS_DATA/settings.conf")"
    rm -rf "$STATE/lock"; kill "$holder" 2>/dev/null; wait "$c"
    check "down applied once the lock is free" "" "$(sed -n 's/^ACTIVE=//p' "$WGS_DATA/settings.conf")"
    check "state off" off "$(st state)"
    check "lock released by ctl" no "$([ -d "$STATE/lock" ] && echo yes || echo no)"
    # a failing command under the lock must not leave it behind
    ctl set killswitch 7 >/dev/null 2>&1
    ctl up no-such-tunnel >/dev/null 2>&1
    check "lock released after a failed command" no "$([ -d "$STATE/lock" ] && echo yes || echo no)"
fi

if want lock_stale; then
    echo "lock_stale: two processes take over a dead holder's lock - one gets it"
    reset_state; mkdir -p "$STATE"
    # both see the dead holder; kill -0 is slowed down so that the second one
    # decides only after the first has taken the lock over
    taker() {  # taker DELAY
        $TSH -c '. "$WGS_MODDIR/sh/common.sh"; D=$1; kill() { sleep "$D"; command kill "$@"; }
            if lock_try; then echo "$$" >> "$2"; sleep 2; fi' sh "$1" "$RUN/got"
    }
    sleep 0 & dead=$!; wait "$dead"
    rm -rf "$STATE/lock" "$RUN/got"; mkdir "$STATE/lock"; echo "$dead" > "$STATE/lock/pid"
    taker 0.3 & t1=$!; taker 0.9 & t2=$!
    sleep 1.5
    check "two takers: one holds the lock" 1 "$(grep -c . "$RUN/got" 2>/dev/null || echo 0)"
    check "the lock is the holder's" "$(head -n 1 "$RUN/got" 2>/dev/null)" "$(cat "$STATE/lock/pid" 2>/dev/null)"
    check "no takeover left inside the lock" no "$([ -d "$STATE/lock/takeover" ] && echo yes || echo no)"
    wait "$t1" "$t2"
    # a takeover left behind by a taker that died: cleared after 30 s
    rm -rf "$STATE/lock" "$RUN/got"; mkdir -p "$STATE/lock/takeover"; echo "$dead" > "$STATE/lock/pid"
    touch -d '@'"$(( $(date +%s) - 60 ))" "$STATE/lock/takeover"
    $TSH -c '. "$WGS_MODDIR/sh/common.sh"; lock_try; lock_try && echo got' > "$RUN/got"
    check "old takeover left behind: lock taken on the next try" got "$(cat "$RUN/got")"
    rm -rf "$STATE/lock" "$RUN/got"
fi

if want backup; then
    echo "backup: zip written, checked, restored"
    reset_state
    conf "$WGS_DL/wg-BG-2.conf" 203.0.113.14:51820
    conf "$WGS_DL/wg-BG-3.conf" 203.0.113.15:51820
    ctl import wg-BG-2.conf >/dev/null; ctl import wg-BG-3.conf >/dev/null
    ctl fav add wg-BG-3 >/dev/null
    check "backup" 2 "$(ctl backup | kv backed_up)"
    check "zip readable by unzip" 0 "$(unzip -tq "$WGS_BACKUP_ROOT/wg-shield-backup.zip" >/dev/null 2>&1; echo $?)"
    ctl removeall >/dev/null
    out=$(ctl restore)
    check "restore imported" 2 "$(echo "$out" | kv imported)"
    check "restore favorites" 1 "$(echo "$out" | kv favorites)"
fi

# tick until the status key has the value (at most N ticks, 1.1 s apart)
tick_until() {  # tick_until KEY VALUE N
    _n=0
    while [ "$_n" -lt "$3" ]; do
        ctl status >/dev/null 2>&1
        [ "$(st "$1")" = "$2" ] && return 0
        sleep 1.1; _n=$((_n + 1))
    done
    return 1
}
setting() { sed -n "s/^$1=//p" "$WGS_DATA/settings.conf"; }

if want heal; then
    echo "heal: restarts, then auto-switch skips the failed server address"
    reset_state
    conf "$WGS_DL/wg-BG-1.conf" 203.0.113.21:51820
    conf "$WGS_DL/wg-BG-2.conf" 203.0.113.21:51820     # same server as BG-1
    conf "$WGS_DL/wg-BG-3.conf" 203.0.113.22:51820
    conf "$WGS_DL/wg-NL-1.conf" 203.0.113.23:51820
    for n in wg-BG-1 wg-BG-2 wg-BG-3 wg-NL-1; do ctl import "$n.conf" >/dev/null; done
    ctl set autoswitch 1 >/dev/null
    date +%s > "$STATE/fake_hs"
    ctl up wg-BG-1 >/dev/null
    check "up" up "$(st state)"
    echo $(( $(date +%s) - 300 )) > "$STATE/fake_hs"     # last handshake 5 min ago
    tick_until recover "restart 1/2" 3; check "restart 1" "restart 1/2" "$(st recover)"
    tick_until recover "restart 2/2" 4; check "restart 2" "restart 2/2" "$(st recover)"
    tick_until recover "switch wg-BG-3" 4; check "switch to the same country, other address" "switch wg-BG-3" "$(st recover)"
    check "settings follow the switch" wg-BG-3 "$(setting ACTIVE)"
    check "kill switch held during recovery" wgs0 "$(route_of)"
    date +%s > "$STATE/fake_hs"
    tick_until state up 3; check "up on the new tunnel" up "$(st state)"
    check "recovery finished" "" "$(st recover)"
    check "switch notified" 1 "$(grep -c 'notification: wg-BG-1 does not answer.*Switched to wg-BG-3' "$WGS_DATA/logs/wg-shield.log")"
    echo "heal: nothing helps - back to the picked tunnel, one notification"
    ctl up wg-NL-1 >/dev/null
    echo $(( $(date +%s) - 300 )) > "$STATE/fake_hs"
    tick_until recover failed 14; check "recovery gave up" failed "$(st recover)"
    check "back on the picked tunnel" wg-NL-1 "$(setting ACTIVE)"
    check "state down" down "$(st state)"
    check "kill switch keeps traffic in the dead tunnel" wgs0 "$(route_of)"
    check "failure notified once" 1 "$(grep -c 'notification: wg-NL-1 does not answer' "$WGS_DATA/logs/wg-shield.log")"
fi

if want pause; then
    echo "pause: direct for a while, resume"
    reset_state
    conf "$WGS_DL/wg-DE-2.conf" 203.0.113.31:51820
    ctl import wg-DE-2.conf >/dev/null
    date +%s > "$STATE/fake_hs"
    ctl up wg-DE-2 >/dev/null
    ctl pause 5 >/dev/null
    check "paused" paused "$(st state)"
    check "paused = direct" wlan0 "$(route_of)"
    ctl resume >/dev/null
    check "resumed" up "$(st state)"
    check "resumed = tunnel" wgs0 "$(route_of)"
    ctl remove wg-DE-2 >/dev/null
    check "removing the active tunnel turns it off" off "$(st state)"
    check "off = direct" wlan0 "$(route_of)"
fi

if want networks; then
    echo "networks: loss of the default network, a second network"
    reset_state
    conf "$WGS_DL/wg-FR-1.conf" 203.0.113.41:51820
    ctl import wg-FR-1.conf >/dev/null
    date +%s > "$STATE/fake_hs"
    ctl up wg-FR-1 >/dev/null
    ip rule del pref 31000; ip rule del pref 16000
    ctl status >/dev/null
    check "no network: still captured (not direct)" wgs0 "$(route_of)"
    check "no network: no wlan0 rules left" 0 "$(ip rule | grep -c 'lookup 1028')"
    ip rule add pref 16000 fwmark 0x10064/0x1ffff iif lo lookup 1028
    ip rule add pref 31000 fwmark 0x0/0xffff iif lo lookup 1028
    ctl status >/dev/null
    check "network back: tunnel" wgs0 "$(route_of)"
    # mobile data next to Wi-Fi: netId 101, table 1029
    ip link add rmnet0 type veth peer name rmnet0p && ip link set rmnet0p up && ip link set rmnet0 up
    ip addr add 10.64.0.2/24 dev rmnet0
    ip route add 10.64.0.0/24 dev rmnet0 table 1029
    ip route add default via 10.64.0.1 dev rmnet0 table 1029
    echo "1029 rmnet0" >> "$WGS_RT_TABLES"
    echo "101 INTERNET&NOT_RESTRICTED&TRUSTED&VALIDATED" >> "$RUN/networks"
    ip rule add pref 16000 fwmark 0x10065/0x1ffff iif lo lookup 1029
    ctl status >/dev/null
    dev_of() { ip route get 1.1.1.1 mark "$1" ${2:+uid $2} 2>&1 | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1; }
    check "socket bound to mobile data -> tunnel" wgs0 "$(dev_of 0x10065)"
    if [ "${WGS_UIDS:-}" = 1 ]; then
        check "Android's check on mobile data stays on it" rmnet0 "$(dev_of 0x10065 1073)"
        check "captive portal app stays on Wi-Fi" wlan0 "$(dev_of 0x10064 10050)"
    else
        echo "  skip uid exemptions (no subuid range: unshare --map-auto failed)"
    fi
    check "status lists it" 1 "$(st nets | grep -c '1029/tunnel')"
    [ "$(st nets | grep -c '1029/tunnel')" = 1 ] || echo "    nets=$(st nets)"
    # an IMS-like restricted network (permission bits 18-19 = SYSTEM): left alone
    ip rule add pref 16000 fwmark 0xd0066/0xdffff iif lo lookup 1029
    ctl status >/dev/null
    check "restricted carrier network not captured" rmnet0 "$(dev_of 0xd0066)"
    ip rule del pref 16000 fwmark 0xd0066/0xdffff iif lo lookup 1029
    ip rule del pref 16000 fwmark 0x10065/0x1ffff iif lo lookup 1029
    ctl status >/dev/null
    check "its rules go with it" 0 "$(ip rule | grep -c 'fwmark 0x65/0xffff')"
    sed -i '/^101 /d' "$RUN/networks"
fi

if want watchdog; then
    echo "watchdog: service.sh, ip monitor fast capture, restart"
    reset_state
    conf "$WGS_DL/wg-IT-1.conf" 203.0.113.51:51820
    ctl import wg-IT-1.conf >/dev/null
    date +%s > "$STATE/fake_hs"
    ctl up wg-IT-1 >/dev/null
    WGS_FAST=1000 $TSH "$MOD/service.sh" </dev/null >/dev/null 2>&1 &
    _n=0; while [ ! -s "$STATE/monitor.pid" ] && [ "$_n" -lt 50 ]; do sleep 0.1; _n=$((_n + 1)); done
    sleep 0.5
    wd=$(cat "$STATE/watchdog.pid" 2>/dev/null)
    check "watchdog running" yes "$(kill -0 "$wd" 2>/dev/null && echo yes || echo no)"
    check "network watch running" yes "$(p=$(cat "$STATE/monitor.pid" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo yes || echo no)"
    echo "102 INTERNET&NOT_RESTRICTED&TRUSTED" >> "$RUN/networks"
    ip rule add pref 16000 fwmark 0x10066/0x1ffff iif lo lookup 1028
    _n=0; while ! ip rule | grep -q '^5022:.*fwmark 0x66/0xffff'; do [ "$_n" -ge 30 ] && break; sleep 0.1; _n=$((_n + 1)); done
    check "new network captured within 3 s" yes "$(ip rule | grep -q '^5022:.*fwmark 0x66/0xffff' && echo yes || echo no)"
    out=$(ctl restart)
    check "restart" 1 "$(echo "$out" | kv restarted)"
    wd2=$(cat "$STATE/watchdog.pid" 2>/dev/null)
    check "old watchdog gone" no "$(kill -0 "$wd" 2>/dev/null && echo yes || echo no)"
    check "new watchdog running" yes "$( [ "$wd2" != "$wd" ] && kill -0 "$wd2" 2>/dev/null && echo yes || echo no)"
    kill "$wd2" 2>/dev/null; sleep 0.5
    p=$(cat "$STATE/monitor.pid" 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null
    ip rule del pref 16000 fwmark 0x10066/0x1ffff iif lo lookup 1028
    sed -i '/^102 /d' "$RUN/networks"
fi

if want dns; then
    echo "dns: app DNS goes to the tunnel's DNS while it captures traffic"
    nat() { cat "$WGS_IPT_DIR/nat" 2>/dev/null; }
    hasnat() { nat | grep -qxF -- "$1" && echo yes || echo no; }
    J="-A OUTPUT -j wgs_dns"; DN="-A wgs_dns -o wgs0 -p udp --dport 53 -j DNAT --to-destination 10.2.0.1:53"
    JS="-A POSTROUTING -j wgs_dnss"; SN="-A wgs_dnss -o wgs0 -d 10.2.0.1 -p udp --dport 53 ! -s 10.2.0.2 -j SNAT --to-source 10.2.0.2"
    export WGS_IP="$FAKES/ipn"
    reset_state; rm -rf "$WGS_IPT_DIR"
    conf "$WGS_DL/wg-DE-1.conf" 203.0.113.61:51820
    ctl import wg-DE-1.conf >/dev/null
    date +%s > "$STATE/fake_hs"
    ctl up wg-DE-1 >/dev/null
    check "OUTPUT jumps to wgs_dns" yes "$(hasnat "$J")"
    check "udp 53 DNAT to the tunnel DNS" yes "$(hasnat "$DN")"
    check "tcp 53 DNAT to the tunnel DNS" yes "$(hasnat "-A wgs_dns -o wgs0 -p tcp --dport 53 -j DNAT --to-destination 10.2.0.1:53")"
    check "only the two DNAT rules (nothing by uid, no LAN resolver)" 2 "$(nat | grep -c -- '^-A wgs_dns ')"
    check "logged" 1 "$(grep -c "apps use the tunnel's DNS 10.2.0.1" "$WGS_DATA/logs/wg-shield.log")"
    check "Wi-Fi LAN resolver stays local (no DNAT on wlan0)" no "$(nat | grep -q -- '-o wlan0' && echo yes || echo no)"
    check "no SNAT chain" "no no" "$(hasnat "$JS") $(nat | grep -qx -- '-N wgs_dnss' && echo yes || echo no)"
    check "status dns=tunnel" "tunnel 10.2.0.1" "$(st dns) $(st dns_server)"
    # a second captured internet network: nothing per network (its DNS is routed into wgs0)
    echo "1031 rmnetx" >> "$WGS_RT_TABLES"
    echo "103 INTERNET&NOT_RESTRICTED&TRUSTED&VALIDATED" >> "$RUN/networks"
    ip rule add pref 16000 fwmark 0x10067/0x1ffff iif lo lookup 1031
    ctl status >/dev/null
    check "second network: chain unchanged" "2 no" "$(nat | grep -c -- '^-A wgs_dns ') $(nat | grep -q rmnetx && echo yes || echo no)"
    ip rule del pref 16000 fwmark 0x10067/0x1ffff iif lo lookup 1031
    sed -i '/^103 /d' "$RUN/networks"; sed -i '/^1031 /d' "$WGS_RT_TABLES"
    "$WGS_IPT" -w -t nat -D OUTPUT -j wgs_dns
    ctl status >/dev/null
    check "jump removed by someone else: repaired" yes "$(hasnat "$J")"
    check "repair logged once" 1 "$(grep -c 'changed by someone else - repaired' "$WGS_DATA/logs/wg-shield.log")"
    "$WGS_IPT" -w -t nat -D wgs_dns -o wgs0 -p tcp --dport 53 -j DNAT --to-destination 10.2.0.1:53
    ctl status >/dev/null
    check "rule removed inside the chain: repaired" "2 1" "$(nat | grep -c -- '^-A wgs_dns ') $(nat | grep -cxF -- "$J")"
    # a chain left by an unreleased build (SNAT): removed
    "$WGS_IPT" -w -t nat -N wgs_dnss; "$WGS_IPT" -w -t nat -A wgs_dnss -o wgs0 -j SNAT --to-source 10.2.0.2; "$WGS_IPT" -w -t nat -A POSTROUTING -j wgs_dnss
    ctl status >/dev/null
    check "old SNAT chain removed" "no no" "$(hasnat "$JS") $(nat | grep -qx -- '-N wgs_dnss' && echo yes || echo no)"
    mkdir -p "$WGS_MODULES/dnscrypt-proxy-android"
    ctl status >/dev/null
    check "DNSCrypt installed but not taking DNS (paused): redirect stays" yes "$(hasnat "$DN")"
    DC="-A OUTPUT -p udp -m udp --dport 53 -j DNAT --to-destination 127.0.0.1:5354"
    echo "$DC" >> "$WGS_IPT_DIR/nat"
    ctl status >/dev/null
    check "DNSCrypt Proxy on: no redirect" no "$(hasnat "$J")"
    check "DNSCrypt Proxy on: chain removed" no "$(nat | grep -qx -- '-N wgs_dns' && echo yes || echo no)"
    check "DNSCrypt Proxy on: status" "dnscrypt " "$(st dns) $(st dns_server)"
    check "DNSCrypt Proxy on: logged" 1 "$(grep -c 'DNS: left to DNSCrypt Proxy' "$WGS_DATA/logs/wg-shield.log")"
    grep -vxF -- "$DC" "$WGS_IPT_DIR/nat" > "$WGS_IPT_DIR/nat.n"; mv "$WGS_IPT_DIR/nat.n" "$WGS_IPT_DIR/nat"
    ctl status >/dev/null
    check "DNSCrypt Proxy paused (its DNAT gone): redirect back" yes "$(hasnat "$DN")"
    rm -rf "$WGS_MODULES/dnscrypt-proxy-android"
    ctl set killswitch 0 >/dev/null
    echo $(( $(date +%s) - 600 )) > "$STATE/fake_hs"
    ctl status >/dev/null
    check "tunnel down, kill switch off: network DNS again" "no network" "$(hasnat "$J") $(st dns)"
    date +%s > "$STATE/fake_hs"; ctl set killswitch 1 >/dev/null; ctl status >/dev/null
    check "up again: redirect back" yes "$(hasnat "$J")"
    ctl down >/dev/null
    check "down: redirect removed" no "$(hasnat "$J")"
    check "down: chain removed" no "$(nat | grep -qx -- '-N wgs_dns' && echo yes || echo no)"
    check "down: status dns empty" "" "$(st dns)"
    sed -i 's#^DNS = .*#DNS = fd00::53, 10.2.0.9, example.lan#' "$WGS_DL/wg-DE-1.conf"
    ctl import wg-DE-1.conf >/dev/null; ctl up wg-DE-1 >/dev/null
    check "first IPv4 of the DNS line" yes "$(hasnat "-A wgs_dns -o wgs0 -p udp --dport 53 -j DNAT --to-destination 10.2.0.9:53")"
    ctl down >/dev/null
    sed -i '/^DNS = /d' "$WGS_DL/wg-DE-1.conf"
    ctl import wg-DE-1.conf >/dev/null; ctl up wg-DE-1 >/dev/null
    check "no DNS line: DNS left alone" "no network" "$(hasnat "$J") $(st dns)"
    ctl down >/dev/null
    conf "$WGS_DL/wg-DE-1.conf" 203.0.113.61:51820
    ctl import wg-DE-1.conf >/dev/null
    WGS_IPT="$RUN/no-iptables" ctl up wg-DE-1 >/dev/null
    WGS_IPT="$RUN/no-iptables" ctl status >/dev/null; WGS_IPT="$RUN/no-iptables" ctl status >/dev/null
    check "no iptables: one warning, no state" "1 no" "$(grep -c "could not send DNS to 10.2.0.1" "$WGS_DATA/logs/wg-shield.log") $([ -f "$STATE/dns.want" ] && echo yes || echo no)"
    check "no iptables: traffic still through the tunnel" wgs0 "$(route_of)"
    ctl down >/dev/null
    export WGS_IP="$REALIP"
fi

if want dns_reboot; then
    echo "dns_reboot: after a reboot the DNS redirect is set up as new, not as repaired"
    export WGS_IP="$FAKES/ipn"
    reset_state; rm -rf "$WGS_IPT_DIR"
    conf "$WGS_DL/wg-DE-4.conf" 203.0.113.63:51820
    ctl import wg-DE-4.conf >/dev/null
    date +%s > "$STATE/fake_hs"
    ctl up wg-DE-4 >/dev/null
    check "redirect on before the reboot" 1 "$(grep -c "apps use the tunnel's DNS 10.2.0.1" "$WGS_DATA/logs/wg-shield.log")"
    rm -rf "$WGS_IPT_DIR"                 # a reboot empties iptables
    $TSH "$MOD/post-fs-data.sh" >/dev/null 2>&1
    ctl status >/dev/null
    check "after the reboot: no 'removed by someone else' warning" 0 "$(grep -c 'changed by someone else - repaired' "$WGS_DATA/logs/wg-shield.log")"
    check "after the reboot: set up again" 2 "$(grep -c "apps use the tunnel's DNS 10.2.0.1" "$WGS_DATA/logs/wg-shield.log")"
    ctl down >/dev/null
    export WGS_IP="$REALIP"
fi

if want dns_route; then
    echo "dns_route: only DNS the routing sends into the tunnel is redirected (real iptables)"
    IPTR=$(command -v iptables 2>/dev/null)
    if [ -z "$IPTR" ] || ! command -v python3 >/dev/null || ! command -v nft >/dev/null || ! "$IPTR" -w -t nat -L -n >/dev/null 2>&1 || ! "$IPTR" -w -t mangle -L -n >/dev/null 2>&1; then
        echo "  skip (no usable iptables nat/mangle, nft or python3 in the namespace)"
    else
        # the host's iptables-nft turns "-m mark" into a match-everything rule
        # when xt_mark is not loaded (it cannot be loaded from the namespace):
        # those rules go in with nft's own meta mark, the same match
        cat > "$FAKES/iptr" <<EOF
#!/bin/sh
case "\$*" in
    *" -t nat -A "*" -m mark --mark "*" -j RETURN") set -- \$*; exec nft add rule ip nat "\$5" meta mark and "\${9#*/}" == "\${9%/*}" return ;;
esac
exec "$IPTR" "\$@"
EOF
        chmod 755 "$FAKES/iptr"
        IPTR0=$IPTR; IPTR="$FAKES/iptr"
        export WGS_IP="$FAKES/ipn"
        reset_state
        # an IMS-like carrier network (permission SYSTEM): stays outside the tunnel
        ip link add rmnet1 type veth peer name rmnet1p && ip link set rmnet1p up && ip link set rmnet1 up
        ip addr add 10.65.0.2/24 dev rmnet1
        ip route add 10.65.0.0/24 dev rmnet1 table 1030
        ip route add default via 10.65.0.1 dev rmnet1 table 1030
        echo "1030 rmnet1" >> "$WGS_RT_TABLES"
        ip rule add pref 16000 fwmark 0xd0066/0xdffff iif lo lookup 1030
        # and one that shares the Wi-Fi's interface (permission SYSTEM, table wlan0)
        ip rule add pref 16000 fwmark 0xd0067/0xdffff iif lo lookup 1028
        conf "$WGS_DL/wg-DE-3.conf" 203.0.113.62:51820
        ctl import wg-DE-3.conf >/dev/null
        date +%s > "$STATE/fake_hs"
        WGS_IPTS=$(command -v iptables-save) WGS_IPT=$IPTR ctl up wg-DE-3 >/dev/null
        # where one UDP query (socket mark as DnsResolver sets it) leaves:
        # "<out interface> <source> <destination>" from counting rules
        dns_leaves() {  # dns_leaves MARK SERVER
            "$IPTR" -w -t mangle -F POSTROUTING
            for o in wlan0 wgs0 rmnet1; do for s in 192.168.1.50 10.2.0.2 10.65.0.2; do for d in "$2" 10.2.0.1; do
                "$IPTR" -w -t mangle -A POSTROUTING -o "$o" -s "$s" -d "$d" -p udp --dport 53 -j ACCEPT
            done; done; done
            python3 -I -c 'import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, getattr(socket, "SO_MARK", 36), int(sys.argv[1], 16))
if len(sys.argv) > 3:
    import os
    os.fchown(s.fileno(), int(sys.argv[3]), -1)   # like netd: a root socket handed to the app uid
try:
    s.connect((sys.argv[2], 53)); s.send(b"q")
except OSError:
    pass' "$1" "$2" ${3:+"$3"}
            "$IPTR" -w -t mangle -L POSTROUTING -v -n -x | awk '$1 ~ /^[0-9]+$/ && $1 > 0 { print $7, $8, $9; exit }'
            "$IPTR" -w -t mangle -F POSTROUTING
        }
        # the source address a query has once it is out of wgs0 (after nat
        # POSTROUTING): counted where it arrives, on wgs0's veth peer
        peer=$(ip -o link show wgs0 | sed -n 's/^[0-9]*: wgs0@\([^:]*\):.*/\1/p')
        ip link set "$peer" up
        # wgs0 is a veth here: no ARP for the tunnel DNS (a real wgs0 has none)
        ip neigh replace 10.2.0.1 lladdr "$(ip -o link show "$peer" | sed -n 's/.*link\/ether \([0-9a-f:]*\).*/\1/p')" dev wgs0 nud permanent
        dns_src_out() {  # dns_src_out MARK SERVER [UID]
            "$IPTR" -w -t mangle -F PREROUTING
            for s in 192.168.1.50 10.2.0.2; do
                "$IPTR" -w -t mangle -A PREROUTING -i "$peer" -s "$s" -d 10.2.0.1 -p udp --dport 53 -j ACCEPT
            done
            dns_leaves "$1" "$2" ${3:+"$3"} >/dev/null
            "$IPTR" -w -t mangle -L PREROUTING -v -n -x | awk '$1 ~ /^[0-9]+$/ && $1 > 0 { print $8; f = 1; exit } END { if (!f) print "none" }'
            "$IPTR" -w -t mangle -F PREROUTING
        }
        check "Wi-Fi LAN resolver: stays local" "wlan0 192.168.1.50 192.168.1.1" "$(dns_leaves 0x10064 192.168.1.1)"
        check "resolver reached through the tunnel: tunnel DNS" "wgs0 10.2.0.2 10.2.0.1" "$(dns_leaves 0x10064 198.51.100.53)"
        check "resolver reached through the tunnel: source unchanged" 10.2.0.2 "$(dns_src_out 0x10064 198.51.100.53)"
        if [ "${WGS_UIDS:-0}" = 1 ]; then
            check "app (uid 10000, root socket like netd): tunnel DNS" "wgs0 10.2.0.2 10.2.0.1" "$(dns_leaves 0x10064 198.51.100.53 10000)"
            check "Android's network check (uid 1073, root socket like netd): its network's DNS" "wlan0 192.168.1.50 198.51.100.53" "$(dns_leaves 0x10064 198.51.100.53 1073)"
            check "captive portal login (uid 10050): its network's DNS" "wlan0 192.168.1.50 198.51.100.53" "$(dns_leaves 0x10064 198.51.100.53 10050)"
        else
            echo "  skip uid cases (no --map-auto)"
        fi
        check "carrier service network: its own resolver" "rmnet1 10.65.0.2 10.65.0.53" "$(dns_leaves 0xd0066 10.65.0.53)"
        check "carrier service network on the Wi-Fi interface: its own resolver" "wlan0 192.168.1.50 192.168.1.1" "$(dns_leaves 0xd0067 192.168.1.1)"
        # LAN DNS through the tunnel (landns=1): DNS leaving through the Wi-Fi
        # goes to the tunnel's DNS too, with the tunnel's own source address
        rctl() { WGS_IPTS=$(command -v iptables-save) WGS_IPT=$IPTR ctl "$@"; }
        rctl set landns 1 >/dev/null
        check "landns: set up once, nothing repaired, no warning" "1 0 0" "$(grep -c 'LAN DNS through the tunnel too' "$WGS_DATA/logs/wg-shield.log") $(grep -c "redirect to the tunnel's DNS was changed by someone else" "$WGS_DATA/logs/wg-shield.log") $(grep -c 'could not send DNS' "$WGS_DATA/logs/wg-shield.log")"
        rctl status >/dev/null
        check "landns: the next tick finds the chains as wanted" "1 0" "$(grep -c 'LAN DNS through the tunnel too' "$WGS_DATA/logs/wg-shield.log") $(grep -c "redirect to the tunnel's DNS was changed by someone else" "$WGS_DATA/logs/wg-shield.log")"
        check "landns: Wi-Fi LAN resolver -> tunnel DNS" "wgs0 192.168.1.50 10.2.0.1" "$(dns_leaves 0x10064 192.168.1.1)"
        check "landns: it leaves wgs0 with the tunnel's own address" 10.2.0.2 "$(dns_src_out 0x10064 192.168.1.1)"
        check "landns: resolver reached through the tunnel: as before" "wgs0 10.2.0.2 10.2.0.1" "$(dns_leaves 0x10064 198.51.100.53)"
        check "landns: a query to the tunnel's DNS itself: untouched" "wgs0 10.2.0.2 10.2.0.1" "$(dns_leaves 0x10064 10.2.0.1)"
        if [ "${WGS_UIDS:-0}" = 1 ]; then
            # no exemption by uid is possible; the redirected query must then
            # reach the tunnel's DNS (the IPv4 re-route after DNAT has no uid)
            check "landns: Android's network check (uid 1073), LAN resolver -> tunnel DNS" "wgs0 192.168.1.50 10.2.0.1" "$(dns_leaves 0x10064 192.168.1.1 1073)"
            check "landns: Android's network check: the tunnel's own address" 10.2.0.2 "$(dns_src_out 0x10064 192.168.1.1 1073)"
            check "landns: Android's network check, resolver outside the LAN -> tunnel DNS" "wgs0 192.168.1.50 10.2.0.1" "$(dns_leaves 0x10064 198.51.100.53 1073)"
        else
            echo "  skip landns uid cases (no --map-auto)"
        fi
        check "landns: carrier service network: its own resolver" "rmnet1 10.65.0.2 10.65.0.53" "$(dns_leaves 0xd0066 10.65.0.53)"
        check "landns: carrier service network on the Wi-Fi interface: its own resolver" "wlan0 192.168.1.50 192.168.1.1" "$(dns_leaves 0xd0067 192.168.1.1)"
        # root's lookup of a host-name endpoint (rule 5001) is not redirected
        ip rule add pref 5001 iif lo to 1.1.1.1/32 lookup 1028
        check "landns: the endpoint lookup's resolver around the tunnel: not redirected" "wlan0 192.168.1.50 1.1.1.1" "$(dns_leaves 0x0 1.1.1.1)"
        ip rule del pref 5001
        # the tunnel stops answering (kill switch on): the network's resolver again
        echo $(( $(date +%s) - 600 )) > "$STATE/fake_hs"
        rctl status >/dev/null
        check "landns, tunnel not up: Wi-Fi LAN resolver stays local" "no wlan0 192.168.1.50 192.168.1.1" "$([ "$(st state)" = up ] && echo yes || echo no) $(dns_leaves 0x10064 192.168.1.1)"
        check "landns, tunnel down: no SNAT chain" 0 "$("$IPTR" -w -t nat -S 2>/dev/null | grep -c wgs_dnss)"
        check "landns, tunnel down: DNS into the tunnel still to its DNS" "wgs0 10.2.0.2 10.2.0.1" "$(dns_leaves 0x10064 198.51.100.53)"
        date +%s > "$STATE/fake_hs"
        rctl status >/dev/null
        check "landns, up again: Wi-Fi LAN resolver -> tunnel DNS" "up wgs0 192.168.1.50 10.2.0.1" "$(st state) $(dns_leaves 0x10064 192.168.1.1)"
        WGS_IPTS=$(command -v iptables-save) WGS_IPT=$IPTR ctl down >/dev/null
        check "down: real nat table clean" 0 "$("$IPTR" -w -t nat -S 2>/dev/null | grep -c wgs_dns)"
        ip rule del pref 16000 fwmark 0xd0067/0xdffff iif lo lookup 1028
        ip rule del pref 16000 fwmark 0xd0066/0xdffff iif lo lookup 1030
        ip link del rmnet1 2>/dev/null
        sed -i '/^1030 /d' "$WGS_RT_TABLES"
        export WGS_IP="$REALIP"; IPTR=$IPTR0
    fi
fi

if want landns; then
    echo "landns: LAN DNS through the tunnel (opt-in): chain layout, rebuilt with the networks, removed"
    nat() { cat "$WGS_IPT_DIR/nat" 2>/dev/null; }
    hasnat() { nat | grep -qxF -- "$1" && echo yes || echo no; }
    natn() { nat | grep -nxF -- "$1" | head -n 1 | cut -d: -f1; }      # line number of a rule
    J="-A OUTPUT -j wgs_dns"; JS="-A POSTROUTING -j wgs_dnss"
    DW="-A wgs_dns -o wgs0 -p udp --dport 53 -j DNAT --to-destination 10.2.0.1:53"
    DL="-A wgs_dns -o wlan0 -p udp --dport 53 -j DNAT --to-destination 10.2.0.1:53"
    DLT="-A wgs_dns -o wlan0 -p tcp --dport 53 -j DNAT --to-destination 10.2.0.1:53"
    SN="-A wgs_dnss -o wgs0 -d 10.2.0.1 -p udp --dport 53 ! -s 10.2.0.2 -j SNAT --to-source 10.2.0.2"
    SNT="-A wgs_dnss -o wgs0 -d 10.2.0.1 -p tcp --dport 53 ! -s 10.2.0.2 -j SNAT --to-source 10.2.0.2"
    export WGS_IP="$FAKES/ipn"
    reset_state; rm -rf "$WGS_IPT_DIR"
    conf "$WGS_DL/wg-LD-1.conf" 203.0.113.64:51820
    ctl import wg-LD-1.conf >/dev/null
    date +%s > "$STATE/fake_hs"
    ctl up wg-LD-1 >/dev/null
    check "default: setting off, only DNS routed into wgs0" "0 2 no no" "$(st landns) $(nat | grep -c -- '^-A wgs_dns ') $(hasnat "$DL") $(hasnat "$JS")"
    # settings written by an older version: no LANDNS line
    grep -v '^LANDNS=' "$WGS_DATA/settings.conf" > "$RUN/settings.old"; cp "$RUN/settings.old" "$WGS_DATA/settings.conf"
    ctl status >/dev/null
    check "settings without the key: off" "0 2" "$(st landns) $(nat | grep -c -- '^-A wgs_dns ')"
    check "set landns: only 0 or 1" 0 "$(ctl set landns 2 2>&1 | kv ok)"
    check "set landns 1" "1 1" "$(ctl set landns 1 | kv ok) $(setting LANDNS)"
    check "status: setting, DNS still the tunnel's, the redirected interface" "1 tunnel 10.2.0.1 wlan0" "$(st landns) $(st dns) $(st dns_server) $(st dns_lan)"
    check "DNS leaving through the Wi-Fi -> tunnel DNS (udp, tcp)" "yes yes" "$(hasnat "$DL") $(hasnat "$DLT")"
    check "DNS routed into the tunnel as before" "yes 1" "$(hasnat "$DW") $(nat | grep -cxF -- "$J")"
    check "SNAT to the tunnel's own address (udp, tcp), one jump" "yes yes 1 2" "$(hasnat "$SN") $(hasnat "$SNT") $(nat | grep -cxF -- "$JS") $(nat | grep -c -- '^-A wgs_dnss ')"
    check "loopback and the tunnel's DNS itself: RETURN, before every redirect" "yes yes" \
        "$([ "$(natn "-A wgs_dns -d 127.0.0.0/8 -j RETURN")" -lt "$(natn "$DW")" ] && echo yes || echo no) $([ "$(natn "-A wgs_dns -d 10.2.0.1 -j RETURN")" -lt "$(natn "$DW")" ] && echo yes || echo no)"
    check "the endpoint lookup's resolvers: RETURN after the wgs0 rules, before the Wi-Fi ones" "yes yes" \
        "$([ "$(natn "-A wgs_dns -d 1.1.1.1 -j RETURN")" -gt "$(natn "$DW")" ] && echo yes || echo no) $([ "$(natn "-A wgs_dns -d 8.8.8.8 -j RETURN")" -lt "$(natn "$DL")" ] && echo yes || echo no)"
    check "nothing by uid" 0 "$(nat | grep -c -- 'owner')"
    check "logged" 1 "$(grep -c 'DNS: LAN DNS through the tunnel too - DNS leaving through wlan0 goes to 10.2.0.1' "$WGS_DATA/logs/wg-shield.log")"
    n0=$(nat | grep -c -- '^-A wgs_dns ')
    ctl status >/dev/null; ctl status >/dev/null
    check "stable: nothing rebuilt by the next ticks" "1 0 $n0" "$(grep -c 'LAN DNS through the tunnel too' "$WGS_DATA/logs/wg-shield.log") $(grep -c "redirect to the tunnel's DNS was changed by someone else" "$WGS_DATA/logs/wg-shield.log") $(nat | grep -c -- '^-A wgs_dns ')"
    # a second internet network that goes through the tunnel: its interface too
    echo "1031 rmnetx" >> "$WGS_RT_TABLES"
    echo "103 INTERNET&NOT_RESTRICTED&TRUSTED&VALIDATED" >> "$RUN/networks"
    ip rule add pref 16000 fwmark 0x10067/0x1ffff iif lo lookup 1031
    ctl status >/dev/null
    check "second captured network: its interface redirected too" "yes wlan0,rmnetx" "$(hasnat "-A wgs_dns -o rmnetx -p udp --dport 53 -j DNAT --to-destination 10.2.0.1:53") $(st dns_lan | tr ' ' ',')"
    check "second captured network: logged, not as a repair" "2 0" "$(grep -c 'LAN DNS through the tunnel too' "$WGS_DATA/logs/wg-shield.log") $(grep -c "redirect to the tunnel's DNS was changed by someone else" "$WGS_DATA/logs/wg-shield.log")"
    # the same network while Android is still checking it: not redirected (a
    # login page may be waiting there), marked RETURN before the interface rules
    echo "100 INTERNET&NOT_RESTRICTED&TRUSTED&VALIDATED" > "$RUN/networks"; echo "103 INTERNET&NOT_RESTRICTED&TRUSTED" >> "$RUN/networks"
    ip rule del pref 16000 fwmark 0x10067/0x1ffff iif lo lookup 1031
    ctl status >/dev/null
    ip rule add pref 16000 fwmark 0x10067/0x1ffff iif lo lookup 1031
    ctl status >/dev/null
    check "network Android is still checking: not redirected" "1 no yes" "$(st nets | grep -c '1031/checking\|rmnetx/checking') $(nat | grep -q -- '-o rmnetx' && echo yes || echo no) $([ "$(natn "-A wgs_dns -m mark --mark 0x67/0xffff -j RETURN")" -gt "$(natn "$DW")" ] 2>/dev/null && echo yes || echo no)"
    ip rule del pref 16000 fwmark 0x10067/0x1ffff iif lo lookup 1031
    sed -i '/^103 /d' "$RUN/networks"; sed -i '/^1031 /d' "$WGS_RT_TABLES"
    # a carrier service network that shares the Wi-Fi's interface: RETURN by its mark, first
    ip rule add pref 16000 fwmark 0xd0068/0xdffff iif lo lookup 1028
    ctl status >/dev/null
    check "network that stays outside: RETURN by its netId mark before any redirect" yes "$([ "$(natn "-A wgs_dns -m mark --mark 0x68/0xffff -j RETURN")" -lt "$(natn "$DW")" ] 2>/dev/null && echo yes || echo no)"
    check "network gone / outside one added: no rmnetx rule left" no "$(nat | grep -q rmnetx && echo yes || echo no)"
    ip rule del pref 16000 fwmark 0xd0068/0xdffff iif lo lookup 1028
    ctl status >/dev/null
    check "outside network gone: its RETURN gone" no "$(nat | grep -q -- '--mark 0x68/0xffff' && echo yes || echo no)"
    # changed by someone else: repaired
    w0=$(grep -c "redirect to the tunnel's DNS was changed by someone else - repaired" "$WGS_DATA/logs/wg-shield.log")
    "$WGS_IPT" -w -t nat -D wgs_dns -o wlan0 -p tcp --dport 53 -j DNAT --to-destination 10.2.0.1:53
    ctl status >/dev/null
    check "Wi-Fi rule removed by someone else: repaired" "yes $((w0 + 1))" "$(hasnat "$DLT") $(grep -c "redirect to the tunnel's DNS was changed by someone else - repaired" "$WGS_DATA/logs/wg-shield.log")"
    "$WGS_IPT" -w -t nat -D POSTROUTING -j wgs_dnss
    ctl status >/dev/null
    check "SNAT jump removed by someone else: repaired" "1 $((w0 + 2))" "$(nat | grep -cxF -- "$JS") $(grep -c "redirect to the tunnel's DNS was changed by someone else - repaired" "$WGS_DATA/logs/wg-shield.log")"
    "$WGS_IPT" -w -t nat -D wgs_dnss -o wgs0 -d 10.2.0.1 -p udp --dport 53 ! -s 10.2.0.2 -j SNAT --to-source 10.2.0.2
    "$WGS_IPT" -w -t nat -A wgs_dnss -o wgs0 -d 10.2.0.1 -p udp --dport 53 ! -s 10.2.0.2 -j SNAT --to-source 10.2.0.20
    ctl status >/dev/null
    check "SNAT to another address (10.2.0.20) is not taken for ours: repaired" "yes no" "$(hasnat "$SN") $(nat | grep -q -- '--to-source 10.2.0.20' && echo yes || echo no)"
    # the tunnel does not answer (kill switch on): the network's resolver must be reachable
    echo $(( $(date +%s) - 600 )) > "$STATE/fake_hs"
    ctl status >/dev/null
    # (the state is down, or handshaking while the self-healing restarts it)
    check "tunnel not up, kill switch on: Wi-Fi DNS left alone, no SNAT, wgs0 rules kept" "no no no 2 yes wgs0" "$([ "$(st state)" = up ] && echo yes || echo no) $(hasnat "$DL") $(hasnat "$JS") $(nat | grep -c -- '^-A wgs_dns ') $(hasnat "$DW") $(route_of)"
    check "tunnel down: status" "1 tunnel -" "$(st landns) $(st dns) $(st dns_lan)-"
    check "tunnel down: no SNAT chain left" no "$(nat | grep -qx -- '-N wgs_dnss' && echo yes || echo no)"
    check "tunnel down: logged" 1 "$(grep -c 'DNS: LAN DNS left to the network again' "$WGS_DATA/logs/wg-shield.log")"
    check "the server did not change: 'apps use the tunnel's DNS' logged once only" 1 "$(grep -c "DNS: apps use the tunnel's DNS 10.2.0.1" "$WGS_DATA/logs/wg-shield.log")"
    date +%s > "$STATE/fake_hs"; ctl status >/dev/null
    check "up again: Wi-Fi DNS redirected again" "up yes yes" "$(st state) $(hasnat "$DL") $(hasnat "$SN")"
    # connecting (no handshake yet) on a new tunnel: not redirected
    conf "$WGS_DL/wg-LD-2.conf" 203.0.113.65:51820
    ctl import wg-LD-2.conf >/dev/null
    rm -f "$STATE/fake_hs"
    ctl up wg-LD-2 >/dev/null
    check "handshaking: Wi-Fi DNS left alone" "handshaking no no yes" "$(st state) $(hasnat "$DL") $(hasnat "$JS") $(hasnat "$DW")"
    date +%s > "$STATE/fake_hs"; ctl status >/dev/null
    check "up: redirected" yes "$(hasnat "$DL")"
    # DNSCrypt Proxy takes DNS: nothing of ours
    DC="-A OUTPUT -p udp -m udp --dport 53 -j DNAT --to-destination 127.0.0.1:5354"
    echo "$DC" >> "$WGS_IPT_DIR/nat"
    ctl status >/dev/null
    check "DNSCrypt Proxy on: no redirect, no SNAT, no chains" "dnscrypt no no 0" "$(st dns) $(hasnat "$J") $(hasnat "$JS") $(nat | grep -c -- 'wgs_dns')"
    grep -vxF -- "$DC" "$WGS_IPT_DIR/nat" > "$WGS_IPT_DIR/nat.n"; mv "$WGS_IPT_DIR/nat.n" "$WGS_IPT_DIR/nat"
    ctl status >/dev/null
    check "DNSCrypt Proxy paused: both back" "yes yes" "$(hasnat "$DL") $(hasnat "$SN")"
    ctl set landns 0 >/dev/null
    check "set landns 0: as before the setting" "0 2 no no no" "$(st landns) $(nat | grep -c -- '^-A wgs_dns ') $(hasnat "$DL") $(hasnat "$JS") $(nat | grep -qx -- '-N wgs_dnss' && echo yes || echo no)"
    ctl set landns 1 >/dev/null
    ctl pause 5 >/dev/null
    check "paused: everything removed" "paused 0" "$(st state) $(nat | grep -c -- 'wgs_dns')"
    ctl resume >/dev/null
    check "resumed: redirected again" "up yes" "$(st state) $(hasnat "$DL")"
    ctl down >/dev/null
    check "down: both chains and both jumps removed" 0 "$(nat | grep -c -- 'wgs_dns')"
    check "down: status" "1 -" "$(st landns) $(st dns_lan)-"
    # a tunnel without a DNS line: nothing to redirect to
    sed -i '/^DNS = /d' "$WGS_DL/wg-LD-1.conf"
    ctl import wg-LD-1.conf >/dev/null; date +%s > "$STATE/fake_hs"; ctl up wg-LD-1 >/dev/null
    check "no DNS line: nothing set up" "up network 0" "$(st state) $(st dns) $(nat | grep -c -- 'wgs_dns')"
    ctl down >/dev/null
    check "lock released" no "$([ -d "$STATE/lock" ] && echo yes || echo no)"
    export WGS_IP="$REALIP"
fi

if want dns_failover; then
    echo "dns_failover: several IPv4 servers in the DNS line - the next one takes over when the active one stops answering"
    nat() { cat "$WGS_IPT_DIR/nat" 2>/dev/null; }
    hasnat() { nat | grep -qxF -- "$1" && echo yes || echo no; }
    natn() { nat | grep -nxF -- "$1" | head -n 1 | cut -d: -f1; }
    dnat_to() { nat | sed -n 's/^-A wgs_dns -o wgs0 -p udp --dport 53 -j DNAT --to-destination //p'; }
    export WGS_IP="$FAKES/ipn"
    reset_state; rm -rf "$WGS_IPT_DIR"
    DQ="$RUN/dnsq.log"; DM="$RUN/dnsmode"; rm -f "$DQ" "$DM"
    # busybox as the check uses it: "--list", "timeout N CMD...", "nslookup
    # NAME SERVER". What a server says is in $DM ("<server> answer|nxdomain|
    # timeout", default answer); the output is what busybox 1.35 prints
    cat > "$FAKES/bbdns" <<EOF
#!/bin/sh
case "\$1" in
    --list) printf 'nslookup\ntimeout\n' ;;
    timeout) shift 2; exec "\$@" ;;
    nslookup)
        echo "\$3 \$2" >> "$DQ"
        case "\$(sed -n "s/^\$3 //p" "$DM" 2>/dev/null | tail -n 1)" in
            timeout) exit 143 ;;
            nxdomain) printf 'Server:\t\t%s\nAddress:\t%s:53\n\n** server can'"'"'t find %s: NXDOMAIN\n\n' "\$3" "\$3" "\$2"; exit 1 ;;
            *) printf 'Server:\t\t%s\nAddress:\t%s:53\n\nNon-authoritative answer:\nName:\t%s\nAddress: 203.0.113.99\n\n' "\$3" "\$3" "\$2" ;;
        esac ;;
    *) exit 127 ;;
esac
EOF
    printf '#!/bin/sh\nexit 0\n' > "$FAKES/ping-ok"
    printf '#!/bin/sh\ncase "$1" in --list) echo timeout ;; *) exit 127 ;; esac\n' > "$FAKES/bbnons"
    chmod 755 "$FAKES/bbdns" "$FAKES/ping-ok" "$FAKES/bbnons"
    mkdir -p "$WGS_SYSNET/wgs0"
    # one liveness check as the watchdog runs it between ticks (the tunnel answers the ping)
    lc() { rm -f "$STATE/live_probe_at"; WGS_PING="$FAKES/ping-ok" WGS_BB="${LCBB:-$FAKES/bbdns}" WGS_DNS_FO_EVERY="${LCEVERY:-0}" $TSH -c '. "$WGS_MODDIR/sh/common.sh"; . "$WGS_MODDIR/sh/tunnels.sh"; . "$WGS_MODDIR/sh/net.sh"; settings_load; live_check; echo "rc=$?"'; }
    asked() { cut -d' ' -f1 "$DQ" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
    conf "$WGS_DL/wg-FO-1.conf" 203.0.113.67:51820
    sed -i 's#^DNS = .*#DNS = 10.2.0.1, fd00::53, 10.2.0.9, example.lan, 10.2.0.1, 10.2.0.7#' "$WGS_DL/wg-FO-1.conf"
    ctl import wg-FO-1.conf >/dev/null
    date +%s > "$STATE/fake_hs"
    ctl up wg-FO-1 >/dev/null
    check "every IPv4 server kept in order (no doubles), after the existing lines of tunnel.info" "10.2.0.1|fd00::53|10.2.0.1 10.2.0.9 10.2.0.7|203.0.113.67" "$(sed -n 10p "$STATE/tunnel.info")|$(sed -n 11p "$STATE/tunnel.info")|$(sed -n 12p "$STATE/tunnel.info")|$(sed -n 3p "$STATE/tunnel.info")"
    check "the first server is the active one" "tunnel 10.2.0.1 10.2.0.1:53" "$(st dns) $(st dns_server) $(dnat_to)"
    check "a query to a listed server is not redirected (RETURN first)" "yes yes yes 5" \
        "$([ "$(natn "-A wgs_dns -d 10.2.0.1 -j RETURN")" -lt "$(natn "-A wgs_dns -o wgs0 -p udp --dport 53 -j DNAT --to-destination 10.2.0.1:53")" ] 2>/dev/null && echo yes || echo no) $(hasnat "-A wgs_dns -d 10.2.0.9 -j RETURN") $(hasnat "-A wgs_dns -d 10.2.0.7 -j RETURN") $(nat | grep -c -- '^-A wgs_dns ')"
    check "the active server answers: asked once, nothing changes" "rc=0 10.2.0.1 example.com 10.2.0.1" "$(lc) $(cat "$DQ") $(st dns_server)"
    : > "$DQ"; echo "10.2.0.1 nxdomain" > "$DM"
    lc >/dev/null; lc >/dev/null; ctl status >/dev/null
    check "'no such name' is an answer too" "10.2.0.1 10.2.0.1|10.2.0.1" "$(asked)|$(st dns_server)"
    : > "$DQ"; echo "10.2.0.1 timeout" > "$DM"
    check "no reply once: no switch yet" "rc=0 no" "$(lc) $([ -f "$STATE/dns_srv" ] && echo yes || echo no)"
    echo "10.2.0.1 answer" > "$DM"; lc >/dev/null; echo "10.2.0.1 timeout" > "$DM"
    check "an answer in between: the count starts again" "rc=0 no" "$(lc) $([ -f "$STATE/dns_srv" ] && echo yes || echo no)"
    check "no reply twice in a row: the next server, tick now" "rc=1 10.2.0.9" "$(lc) $(sed -n 1p "$STATE/dns_srv")"
    check "warning in the log" 1 "$(grep -c 'WARN.*DNS: 10.2.0.1 does not answer through the tunnel.* - switching to 10.2.0.9' "$WGS_DATA/logs/wg-shield.log")"
    ctl status >/dev/null
    check "the tick redirects to the next server; status shows it" "10.2.0.9:53 tunnel 10.2.0.9 2" "$(dnat_to) $(st dns) $(st dns_server) $(nat | grep -c -- '--to-destination 10.2.0.9:53$')"
    check "listed servers still RETURN, nothing left of the old target" "yes yes 0 5" "$(hasnat "-A wgs_dns -d 10.2.0.1 -j RETURN") $(hasnat "-A wgs_dns -d 10.2.0.9 -j RETURN") $(nat | grep -c -- '--to-destination 10.2.0.1:53$') $(nat | grep -c -- '^-A wgs_dns ')"
    check "logged as a new DNS, not as a repair" "1 0" "$(grep -c "apps use the tunnel's DNS 10.2.0.9" "$WGS_DATA/logs/wg-shield.log") $(grep -c "redirect to the tunnel's DNS was changed by someone else" "$WGS_DATA/logs/wg-shield.log")"
    : > "$DQ"; rm -f "$DM"
    lc >/dev/null; lc >/dev/null; ctl status >/dev/null
    check "it stays on the server that answers; that one is asked" "10.2.0.9 10.2.0.9|10.2.0.9" "$(asked)|$(st dns_server)"
    printf '10.2.0.9 timeout\n10.2.0.7 timeout\n' > "$DM"
    lc >/dev/null; lc >/dev/null; ctl status >/dev/null
    check "the second one fails too: the third" 10.2.0.7 "$(st dns_server)"
    lc >/dev/null; lc >/dev/null; ctl status >/dev/null
    check "the last one fails: around to the first" "10.2.0.1 10.2.0.1:53" "$(st dns_server) $(dnat_to)"
    rm -f "$DM"
    # at most one question a minute
    : > "$DQ"; rm -f "$STATE/dns_fo_at"
    LCEVERY=60 lc >/dev/null; LCEVERY=60 lc >/dev/null; LCEVERY=60 lc >/dev/null
    check "at most one question in 60 s" 1 "$(grep -c . "$DQ")"
    # a result that belongs to another tunnel load is not used
    printf '10.2.0.9\nsome-other-tunnel 123\n' > "$STATE/dns_srv"
    ctl status >/dev/null
    check "a switch noted for another tunnel load is ignored" 10.2.0.1 "$(st dns_server)"
    # reset to the first server when the tunnel is loaded again / another one / off
    echo "10.2.0.1 timeout" > "$DM"; lc >/dev/null; lc >/dev/null; ctl status >/dev/null
    check "(on the second server again)" 10.2.0.9 "$(st dns_server)"
    ctl restart >/dev/null 2>&1; wd=$(cat "$STATE/watchdog.pid" 2>/dev/null); [ -n "$wd" ] && kill "$wd" 2>/dev/null; sleep 0.3
    p=$(cat "$STATE/monitor.pid" 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null
    date +%s > "$STATE/fake_hs"; ctl status >/dev/null
    check "tunnel loaded again: the first server" "up 10.2.0.1 no" "$(st state) $(st dns_server) $([ -f "$STATE/dns_srv" ] && echo yes || echo no)"
    lc >/dev/null; lc >/dev/null; ctl status >/dev/null
    check "(on the second server again)" 10.2.0.9 "$(st dns_server)"
    ctl down >/dev/null
    check "tunnel off: nothing kept" "no no" "$([ -f "$STATE/dns_srv" ] && echo yes || echo no) $([ -f "$STATE/dns_fo_fail" ] && echo yes || echo no)"
    date +%s > "$STATE/fake_hs"; ctl up wg-FO-1 >/dev/null
    check "on again: the first server" 10.2.0.1 "$(st dns_server)"
    # LAN DNS through the tunnel follows the active server
    ctl set landns 1 >/dev/null
    check "landns: SNAT for the active server, every listed server RETURN" "yes yes yes" "$(hasnat "-A wgs_dnss -o wgs0 -d 10.2.0.1 -p udp --dport 53 ! -s 10.2.0.2 -j SNAT --to-source 10.2.0.2") $(hasnat "-A wgs_dns -d 10.2.0.9 -j RETURN") $(hasnat "-A wgs_dns -o wlan0 -p udp --dport 53 -j DNAT --to-destination 10.2.0.1:53")"
    lc >/dev/null; lc >/dev/null; ctl status >/dev/null
    check "landns: after the switch both follow" "10.2.0.9 yes yes 0" "$(st dns_server) $(hasnat "-A wgs_dnss -o wgs0 -d 10.2.0.9 -p udp --dport 53 ! -s 10.2.0.2 -j SNAT --to-source 10.2.0.2") $(hasnat "-A wgs_dns -o wlan0 -p udp --dport 53 -j DNAT --to-destination 10.2.0.9:53") $(nat | grep -c -- '-d 10.2.0.1 -p')"
    ctl set landns 0 >/dev/null
    rm -f "$DM"
    # not asked at all: DNSCrypt Proxy takes DNS, no busybox / no nslookup, one server only
    ctl down >/dev/null; date +%s > "$STATE/fake_hs"; ctl up wg-FO-1 >/dev/null
    DC="-A OUTPUT -p udp -m udp --dport 53 -j DNAT --to-destination 127.0.0.1:5354"
    echo "$DC" >> "$WGS_IPT_DIR/nat"; ctl status >/dev/null
    : > "$DQ"; echo "10.2.0.1 timeout" > "$DM"
    lc >/dev/null; lc >/dev/null
    check "DNSCrypt Proxy takes DNS: nothing asked" "dnscrypt 0" "$(st dns) $(grep -c . "$DQ")"
    grep -vxF -- "$DC" "$WGS_IPT_DIR/nat" > "$WGS_IPT_DIR/nat.n"; mv "$WGS_IPT_DIR/nat.n" "$WGS_IPT_DIR/nat"; ctl status >/dev/null
    LCBB="$RUN/no-busybox" lc >/dev/null; LCBB="$RUN/no-busybox" lc >/dev/null
    LCBB="$FAKES/bbnons" lc >/dev/null; LCBB="$FAKES/bbnons" lc >/dev/null
    check "no busybox, or one without nslookup: nothing asked, no switch" "0 no" "$(grep -c . "$DQ") $([ -f "$STATE/dns_srv" ] && echo yes || echo no)"
    ctl down >/dev/null
    conf "$WGS_DL/wg-FO-2.conf" 203.0.113.68:51820
    ctl import wg-FO-2.conf >/dev/null; date +%s > "$STATE/fake_hs"; ctl up wg-FO-2 >/dev/null
    echo "10.2.0.1 timeout" > "$DM"; : > "$DQ"
    lc >/dev/null; lc >/dev/null
    check "one server only: nothing asked, the chain as always" "0 2 10.2.0.1" "$(grep -c . "$DQ") $(nat | grep -c -- '^-A wgs_dns ') $(sed -n 12p "$STATE/tunnel.info")"
    ctl down >/dev/null
    rm -rf "$WGS_SYSNET/wgs0" "$DM" "$DQ"
    export WGS_IP="$REALIP"
fi

if want dns6; then
    echo "dns6: IPv6 app DNS goes to the tunnel's IPv6 DNS while the tunnel carries IPv6"
    export WGS_IP="$FAKES/ipn"
    nat() { cat "$WGS_IPT_DIR/nat" 2>/dev/null; }
    hasnat() { nat | grep -qxF -- "$1" && echo yes || echo no; }
    nat6() { cat "$WGS_IPT_DIR/v6/nat" 2>/dev/null; }
    hasnat6() { nat6 | grep -qxF -- "$1" && echo yes || echo no; }
    J6="-A OUTPUT -j wgs_dns"; JS6="-A POSTROUTING -j wgs_dnss"
    DN6="-A wgs_dns -o wgs0 -p udp --dport 53 -j DNAT --to-destination [fd00::53]:53"
    SN6="-A wgs_dnss -o wgs0 -d fd00::53 -p udp --dport 53 ! -s fd00::2 -j SNAT --to-source fd00::2"
    reset_state; rm -rf "$WGS_IPT_DIR"
    echo 0 > "$WGS_PROC6/all/disable_ipv6"; mkdir -p "$WGS_PROC6/wgs0"; echo 0 > "$WGS_PROC6/wgs0/disable_ipv6"
    conf "$WGS_DL/wg-CH-6.conf" 203.0.113.66:51820
    sed -i 's#^Address = .*#Address = 10.2.0.2/32, fd00::2/128#; s#^AllowedIPs = .*#AllowedIPs = 0.0.0.0/0, ::/0#; s#^DNS = .*#DNS = 10.2.0.1, fd00::53#' "$WGS_DL/wg-CH-6.conf"
    ctl import wg-CH-6.conf >/dev/null
    date +%s > "$STATE/fake_hs"
    ctl up wg-CH-6 >/dev/null
    check "IPv6 through the tunnel" tunnel "$(st ipv6)"
    check "IPv6: OUTPUT jumps to wgs_dns" yes "$(hasnat6 "$J6")"
    check "IPv6: udp 53 into the tunnel to the IPv6 DNS" yes "$(hasnat6 "$DN6")"
    check "IPv6: tcp 53 into the tunnel to the IPv6 DNS" yes "$(hasnat6 "-A wgs_dns -o wgs0 -p tcp --dport 53 -j DNAT --to-destination [fd00::53]:53")"
    check "IPv6: only the two DNAT rules" 2 "$(nat6 | grep -c -- '^-A wgs_dns ')"
    check "IPv6: status lists both servers" "tunnel 10.2.0.1 fd00::53" "$(st dns) $(st dns_server)"
    check "IPv4 redirect as before" yes "$(hasnat "-A wgs_dns -o wgs0 -p udp --dport 53 -j DNAT --to-destination 10.2.0.1:53")"
    check "logged" 1 "$(grep -c "apps use the tunnel's DNS fd00::53 for IPv6" "$WGS_DATA/logs/wg-shield.log")"
    "$WGS_IPT6" -w -t nat -D OUTPUT -j wgs_dns
    ctl status >/dev/null
    check "IPv6: jump removed by someone else: repaired" yes "$(hasnat6 "$J6")"
    # IPv6 goes off for the phone: the tunnel carries IPv4 only
    echo 1 > "$WGS_PROC6/all/disable_ipv6"
    ctl status >/dev/null
    check "IPv6 off: IPv6 redirect removed" "no no no" "$(hasnat6 "$J6") $(hasnat6 "$JS6") $(nat6 | grep -qx -- '-N wgs_dns' && echo yes || echo no)"
    check "IPv6 off: IPv4 redirect kept" yes "$(hasnat "-A wgs_dns -o wgs0 -p udp --dport 53 -j DNAT --to-destination 10.2.0.1:53")"
    check "IPv6 off: IPv6 DNS into the tunnel unreachable" unreachable "$(ip -6 route get 2001:db8::53 mark 0x10064 2>&1 | grep -q unreachable && echo unreachable || echo reachable)"
    echo 0 > "$WGS_PROC6/all/disable_ipv6"
    ctl status >/dev/null
    check "IPv6 on again: redirect back" yes "$(hasnat6 "$DN6")"
    ctl down >/dev/null
    check "down: IPv6 redirect and SNAT removed" "no no" "$(hasnat6 "$J6") $(hasnat6 "$JS6")"
    WGS_IPT6="$RUN/no-ip6tables" WGS_IPTS6="$RUN/no-ip6tables-save" ctl up wg-CH-6 >/dev/null
    WGS_IPT6="$RUN/no-ip6tables" WGS_IPTS6="$RUN/no-ip6tables-save" ctl status >/dev/null
    check "no ip6tables nat: one warning, no state" "1 no" "$(grep -c "could not send DNS for IPv6 to fd00::53" "$WGS_DATA/logs/wg-shield.log") $([ -f "$STATE/dns6.want" ] && echo yes || echo no)"
    check "no ip6tables nat: IPv4 redirect kept" yes "$(hasnat "-A wgs_dns -o wgs0 -p udp --dport 53 -j DNAT --to-destination 10.2.0.1:53")"
    ctl down >/dev/null
    # real ip6tables: a carrier IPv6 resolver routed into the tunnel
    IP6R=$(command -v ip6tables 2>/dev/null)
    if [ -n "$IP6R" ] && command -v python3 >/dev/null && "$IP6R" -w -t nat -L -n >/dev/null 2>&1 && "$IP6R" -w -t mangle -L -n >/dev/null 2>&1; then
        # the server in a long form with capitals: ip6tables prints it as fd00::53
        sed -i 's#^DNS = .*#DNS = 10.2.0.1, FD00:0:0:0::53#' "$WGS_DL/wg-CH-6.conf"
        ctl import wg-CH-6.conf >/dev/null
        REP0=$(grep -c 'DNS for IPv6: the redirect .* repaired' "$WGS_DATA/logs/wg-shield.log")
        WGS_IPTS6=$(command -v ip6tables-save) WGS_IPT6=$IP6R ctl up wg-CH-6 >/dev/null
        WGS_IPTS6=$(command -v ip6tables-save) WGS_IPT6=$IP6R ctl status >/dev/null
        check "real ip6tables: IPv6 DNS in a long form: set up once, no warning" "1 0 $REP0" "$(grep -c "apps use the tunnel's DNS FD00:0:0:0::53 for IPv6" "$WGS_DATA/logs/wg-shield.log") $(grep -c 'could not send DNS for IPv6 to FD00' "$WGS_DATA/logs/wg-shield.log") $(grep -c 'DNS for IPv6: the redirect .* repaired' "$WGS_DATA/logs/wg-shield.log")"
        "$IP6R" -w -t mangle -F POSTROUTING
        "$IP6R" -w -t mangle -A POSTROUTING -o wgs0 -s fd00::2 -d fd00::53 -p udp --dport 53 -j ACCEPT
        python3 -I -c 'import socket
s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, getattr(socket, "SO_MARK", 36), 0x10064)
try:
    s.connect(("2001:db8::53", 53)); s.send(b"q")
except OSError:
    pass'
        check "real ip6tables: carrier IPv6 resolver -> tunnel IPv6 DNS" 1 "$("$IP6R" -w -t mangle -L POSTROUTING -v -n -x | awk '$1 ~ /^[0-9]+$/ { print $1; exit }')"
        "$IP6R" -w -t mangle -F POSTROUTING
        WGS_IPTS6=$(command -v ip6tables-save) WGS_IPT6=$IP6R ctl down >/dev/null
        check "real ip6tables: down, nat table clean" 0 "$("$IP6R" -w -t nat -S 2>/dev/null | grep -c wgs_dns)"
    else
        echo "  skip real ip6tables (no usable ip6tables nat/mangle or python3)"
    fi
    echo 1 > "$WGS_PROC6/all/disable_ipv6"
    export WGS_IP="$REALIP"
fi

if want webui; then
    echo "webui: the page script, and tunnel names kept out of handler code (node)"
    if command -v node >/dev/null; then
        mkdir -p "$RUN/webui"
        sed -n '/<script>/,/<\/script>/p' "$REPO/webroot/index.html" | sed '1d;$d' > "$RUN/webui/page.js"
        check "page script parses (node --check)" 0 "$(node --check "$RUN/webui/page.js" >/dev/null 2>&1; echo $?)"
        check "no inline handler interpolates a value" 0 "$(grep -cE 'on(click|change|input)="[^"]*\$\{' "$REPO/webroot/index.html")"
        node "$REPO/tests/webui_rows.js" "$REPO/webroot/index.html" > "$RUN/webui/rows.txt" 2>&1
        while IFS= read -r l; do
            case "$l" in
                "  ok   "*) check "${l#  ok   }" ok ok ;;
                "  FAIL "*) check "${l#  FAIL }" ok fail ;;
                *) check "row test: $l" ok fail ;;
            esac
        done < "$RUN/webui/rows.txt"
    else
        echo "  skip (node missing)"
    fi
fi

if want resolve; then
    echo "resolve: host-name endpoint - only root's DNS query goes around the tunnel"
    reset_state
    RL="$RUN/resolve.log"; rm -f "$RL"
    # busybox as resolve_host uses it ("timeout N CMD...", "nslookup NAME
    # SERVER"); nslookup notes rule 5001 and where root's DNS query and an
    # app's connection to the same address would go at that moment
    cat > "$FAKES/bb" <<EOF
#!/bin/sh
dev() { case "\$1" in *"dev wgs0"*) echo wgs0 ;; *"dev wlan0"*) echo wlan0 ;; *) echo blocked ;; esac; }
case "\$1" in
    timeout) shift 2; exec "\$@" ;;
    nslookup)
        r=\$("$REALIP" rule | sed -n 's/^5001:[[:space:]]*//p' | tr -s '\t ' ' ' | sed 's/ \$//')
        q=\$("$REALIP" route get "\$3" uid 0 ipproto udp dport 53 2>&1 | head -n 1)
        a=\$("$REALIP" route get "\$3" uid 10000 ipproto tcp dport 853 2>&1 | head -n 1)
        echo "\$3|\$r|\$(dev "\$q")|\$(dev "\$a")" >> "$RL"
        [ "\$3" = 1.0.0.1 ] || exit 1
        printf 'Server:\t\t%s\nAddress:\t%s:53\n\nName:\t%s\nAddress: 203.0.113.80\n' "\$3" "\$3" "\$2" ;;
    *) exit 127 ;;
esac
EOF
    chmod 755 "$FAKES/bb"
    conf "$WGS_DL/wg-HO-1.conf" vpn.example.com:51820
    ctl import wg-HO-1.conf >/dev/null
    date +%s > "$STATE/fake_hs"
    WGS_BB="$FAKES/bb" ctl up wg-HO-1 >/dev/null
    check "Cloudflare first; the second resolver answers" "1.1.1.1 1.0.0.1" "$(cut -d'|' -f1 "$RL" | tr '\n' ' ' | sed 's/ $//')"
    check "the tunnel is up on the address from the lookup" "up 203.0.113.80:51820" "$(st state) $(st endpoint)"
    check "rule 5001: root's DNS query to the resolver only" "from all to 1.1.1.1 iif lo uidrange 0-0 dport 53 lookup 1028" "$(sed -n 1p "$RL" | cut -d'|' -f2)"
    # the tunnel stops answering while it captures traffic: the name is looked up again
    : > "$RL"
    echo 0 > "$STATE/resolved_at"; echo $(( $(date +%s) - 600 )) > "$STATE/fake_hs"
    WGS_BB="$FAKES/bb" ctl status >/dev/null
    check "looked up again: root's query leaves on the network" wlan0 "$(sed -n 1p "$RL" | cut -d'|' -f3)"
    if [ "${WGS_UIDS:-0}" = 1 ]; then
        check "meanwhile an app's connection to the resolver's address stays in the tunnel" wgs0 "$(sed -n 1p "$RL" | cut -d'|' -f4)"
    else
        echo "  skip app uid case (no --map-auto)"
    fi
    check "no rule 5001 left" 0 "$(ip rule | grep -c '^5001:')"
    # an ip without "dport" in rules, then one without uidrange: still looked up
    for v in dport uidrange; do
        printf '#!/bin/sh\ncase "$*" in *"pref 5001"*"%s"*) exit 2 ;; esac\nexec "%s" "$@"\n' "$v" "$REALIP" > "$FAKES/ip-no$v"; chmod 755 "$FAKES/ip-no$v"
        ctl down >/dev/null; : > "$RL"; date +%s > "$STATE/fake_hs"
        WGS_IP="$FAKES/ip-no$v" WGS_BB="$FAKES/bb" ctl up wg-HO-1 >/dev/null
        check "ip without $v in rules: looked up, $( [ "$v" = dport ] && echo 'uid only' || echo 'as before')" "up $( [ "$v" = dport ] && echo 'from all to 1.1.1.1 iif lo uidrange 0-0 lookup 1028' || echo 'from all to 1.1.1.1 iif lo lookup 1028')" "$(st state) $(sed -n 1p "$RL" | cut -d'|' -f2)"
    done
    ctl down >/dev/null
fi

if want exitip; then
    echo "exitip: the exit address is asked over HTTPS first (fake curl, no network)"
    reset_state; mkdir -p "$STATE"
    CD="$RUN/curl"; rm -rf "$CD"; mkdir -p "$CD/path"
    export WGS_CURLLOG="$CD/log" WGS_CURLMODE="$CD/mode" WGS_CURLDIR="$CD"
    # curl: notes its arguments; what a URL answers is in $WGS_CURLMODE
    # ("<part of the URL> <file in $CD | fail>", no line = fail)
    cat > "$CD/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do u=$a; done
echo "${WGS_CURLTAG:-sys} $*" >> "$WGS_CURLLOG"
m=$(awk -v u="$u" 'index(u, $1) { print $2; exit }' "$WGS_CURLMODE" 2>/dev/null)
case "$m" in ""|fail) exit 35 ;; esac
cat "$WGS_CURLDIR/$m"
EOF
    printf '#!/bin/sh\nWGS_CURLTAG=path exec "%s" "$@"\n' "$CD/curl" > "$CD/path/curl"
    chmod 755 "$CD/curl" "$CD/path/curl"
    # the services' answers (pretty-printed, as they send them; documentation addresses)
    cat > "$CD/ipinfo.json" <<'EOF'
{
  "ip": "203.0.113.7",
  "hostname": "host.example.net",
  "city": "Exampleton",
  "region": "Example Region",
  "country": "ZZ",
  "loc": "0.0000,0.0000",
  "org": "AS64500 Example Net",
  "timezone": "Etc/UTC",
  "readme": "https://ipinfo.io/missingauth"
}
EOF
    cat > "$CD/ipwho.json" <<'EOF'
{
    "ip": "203.0.113.8",
    "success": true,
    "type": "IPv4",
    "country": "Exampleland",
    "country_code": "ZZ",
    "city": "Sampleville",
    "connection": {
        "asn": 64500,
        "org": "Example Org",
        "isp": "Example ISP",
        "domain": "example.net"
    }
}
EOF
    echo '{"status":"success","country":"Exampleland","countryCode":"ZZ","city":"Testburg","isp":"Plain ISP","query":"203.0.113.9"}' > "$CD/ipapi.json"
    echo '{"ip": "203.0.113.66<script>", "country": "XX"}' > "$CD/bad.json"
    ex() { WGS_CURL="$CD/curl" WGS_BB="$RUN/no-busybox" PATH="$CD/path:$PATH" ctl exitip 2>&1; }
    keys() { sed 's/=.*//' | tr '\n' ' ' | sed 's/ $//'; }
    printf 'ipinfo.io ipinfo.json\nipwho.is ipwho.json\nip-api.com ipapi.json\n' > "$WGS_CURLMODE"
    out=$(ex)
    check "HTTPS, first service: its address, place and provider" "ip=203.0.113.7|country=ZZ|city=Exampleton|isp=AS64500 Example Net|proto=https|ok=1" "$(echo "$out" | grep -E '^(ip|country|city|isp|proto|ok)=' | tr '\n' '|' | sed 's/|$//')"
    check "the output keys: the old ones in their order, proto added" "ip country city isp via proto ok" "$(echo "$out" | keys)"
    check "one request: curl -s --max-time 8 to https://ipinfo.io/json, the certificate checked" "1|sys -s --max-time 8 https://ipinfo.io/json|0" "$(grep -c . "$WGS_CURLLOG")|$(cat "$WGS_CURLLOG")|$(grep -c -e ' -k' -e 'insecure' "$WGS_CURLLOG")"
    check "tunnel off: via empty" "via=" "$(echo "$out" | grep '^via=')"
    : > "$WGS_CURLLOG"; printf 'ipinfo.io fail\nipwho.is ipwho.json\nip-api.com ipapi.json\n' > "$WGS_CURLMODE"
    out=$(ex)
    check "first service fails: the second one over HTTPS" "ip=203.0.113.8|country=Exampleland|city=Sampleville|isp=Example ISP|proto=https|ok=1" "$(echo "$out" | grep -E '^(ip|country|city|isp|proto|ok)=' | tr '\n' '|' | sed 's/|$//')"
    check "both asked over HTTPS, nothing over HTTP" "2 0" "$(grep -c 'https://' "$WGS_CURLLOG") $(grep -c ' http://' "$WGS_CURLLOG")"
    : > "$WGS_CURLLOG"; printf 'ipinfo.io bad.json\nipwho.is ipwho.json\n' > "$WGS_CURLMODE"
    check "an answer whose address is not an address is not used" "ip=203.0.113.8" "$(ex | grep '^ip=')"
    : > "$WGS_CURLLOG"; printf 'https://ipinfo.io fail\nhttps://ipwho.is fail\nip-api.com ipapi.json\n' > "$WGS_CURLMODE"
    out=$(ex)
    check "both HTTPS requests fail: plain HTTP as before, and it says so" "ip=203.0.113.9|country=Exampleland|city=Testburg|isp=Plain ISP|proto=http|ok=1" "$(echo "$out" | grep -E '^(ip|country|city|isp|proto|ok)=' | tr '\n' '|' | sed 's/|$//')"
    check "HTTP only after both HTTPS requests" "sys sys path" "$(cut -d' ' -f1 "$WGS_CURLLOG" | tr '\n' ' ' | sed 's/ $//')"
    check "the HTTP request is the old one" 1 "$(grep -c '^path -s -m 8 http://ip-api.com/json/?fields=status,country,countryCode,city,isp,query$' "$WGS_CURLLOG")"
    : > "$WGS_CURLLOG"
    out=$(WGS_CURL="$RUN/no-curl" WGS_BB="$RUN/no-busybox" PATH="$CD/path:$PATH" ctl exitip 2>&1)
    check "no curl for HTTPS: plain HTTP at once" "ip=203.0.113.9 proto=http 0" "$(echo "$out" | grep '^ip=') $(echo "$out" | grep '^proto=') $(grep -c 'https://' "$WGS_CURLLOG")"
    : > "$WGS_CURLMODE"
    out=$(ex)
    check "nothing answers: an error, no address" "0 0 1" "$(echo "$out" | kv ok) $(echo "$out" | grep -c '^ip=') $(echo "$out" | grep -c '^error=no answer')"
    # through the tunnel: via says so, as before
    conf "$WGS_DL/wg-EX-1.conf" 203.0.113.91:51820
    ctl import wg-EX-1.conf >/dev/null; date +%s > "$STATE/fake_hs"; ctl up wg-EX-1 >/dev/null
    printf 'ipinfo.io ipinfo.json\n' > "$WGS_CURLMODE"
    out=$(ex)
    check "tunnel up: via=wgs0 as before, proto next to it" "via=wgs0 proto=https" "$(echo "$out" | grep '^via=') $(echo "$out" | grep '^proto=')"
    ctl down >/dev/null
    unset WGS_CURLLOG WGS_CURLMODE WGS_CURLDIR
fi

if want ks_error; then
    echo "ks_error: with the setting on, a tunnel that cannot be built blocks traffic like a down one (kill switch)"
    nat() { cat "$WGS_IPT_DIR/nat" 2>/dev/null; }
    lan_of() { r=$(ip route get 192.168.1.1 2>&1 | head -n1); case "$r" in *"dev wlan0"*) echo wlan0 ;; *) echo other ;; esac; }
    r4() { ip rule | grep -c "^$1:"; }
    r6() { ip -6 rule | grep -c "^$1:"; }
    desc() { sed -n 's/^description=.*Status: //p' "$MOD/module.prop"; }
    logn() { grep -c -- "$1" "$WGS_DATA/logs/wg-shield.log"; }
    reset_state; rm -rf "$WGS_IPT_DIR"
    conf "$WGS_DL/wg-KE-1.conf" 203.0.113.92:51820
    conf "$WGS_DL/wg-KE-2.conf" 203.0.113.93:51820
    ctl import wg-KE-1.conf >/dev/null; ctl import wg-KE-2.conf >/dev/null
    date +%s > "$STATE/fake_hs"
    ctl up wg-KE-1 >/dev/null
    check "up; the setting is off by default" "up 0 1" "$(st state) $(st ks_error) $(st killswitch)"
    # the tunnel file disappears: error. Default: direct connection, as documented
    mv "$WGS_DATA/tunnels/wg-KE-1.conf" "$RUN/ke1.conf"
    ctl status >/dev/null
    check "default: error = direct connection, everything removed" "error tunnel_missing wlan0 0 0 no" "$(st state) $(st reason) $(route_of) $(r4 5020) $(ip route show table 51820 2>/dev/null | grep -c .) $(ip link show wgs0 >/dev/null 2>&1 && echo yes || echo no)"
    check "default: logged and described as direct" "1 0 1" "$(logn 'state: error (tunnel_missing) - direct connection') $(logn 'state: error (tunnel_missing) - kill switch blocks traffic') $(desc | grep -c 'Error: tunnel_missing · direct connection')"
    # settings written by an older version: no KS_ERROR line
    grep -v '^KS_ERROR=' "$WGS_DATA/settings.conf" > "$RUN/settings.old"; cp "$RUN/settings.old" "$WGS_DATA/settings.conf"
    ctl status >/dev/null
    check "settings without the key: off" "0 wlan0" "$(st ks_error) $(route_of)"
    check "set ks_error: only 0 or 1" 0 "$(ctl set ks_error on 2>&1 | kv ok)"
    check "set ks_error 1" "1 1" "$(ctl set ks_error 1 | kv ok) $(setting KS_ERROR)"
    check "error + kill switch + the setting: traffic blocked in that tick" "error tunnel_missing 1 blocked" "$(st state) $(st reason) $(st ks_error) $(route_of)"
    check "blocked like a down tunnel: capture rules, the unreachable route, no interface, no endpoint rule" "1 1 0 0 1 no" "$(r4 5020) $(r4 5021) $(r4 5000) $(ip -6 rule | grep -c '^5000:') $(ip route show table 51820 | grep -c '^unreachable default') $(ip link show wgs0 >/dev/null 2>&1 && echo yes || echo no)"
    check "only the unreachable route in table 51820" 1 "$(ip route show table 51820 | grep -c .)"
    check "IPv6 unreachable" "1 1" "$(ip -6 rule | grep -c '^5020:.*unreachable') $(ip -6 rule | grep -c '^5021:.*unreachable')"
    check "the Wi-Fi LAN stays reachable (local rules kept)" "wlan0 1 1" "$(lan_of) $(r4 5010) $(r4 5012)"
    if [ "${WGS_UIDS:-}" = 1 ]; then
        check "Android's network check stays on its network" wlan0 "$(ip route get 1.1.1.1 mark 0x10064 uid 1073 2>&1 | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)"
    else
        echo "  skip uid case (no --map-auto)"
    fi
    check "a socket bound to the network is blocked too" blocked "$(ip route get 1.1.1.1 mark 0x10064 2>&1 | grep -q 'dev ' && echo open || echo blocked)"
    check "logged, described" "1 1" "$(logn 'state: error (tunnel_missing) - kill switch blocks traffic') $(desc | grep -c 'Error: tunnel_missing · internet blocked (kill switch)')"
    check "no DNS redirect left" 0 "$(nat | grep -c wgs_dns)"
    w0=$(grep -c 'WARN' "$WGS_DATA/logs/wg-shield.log")
    ctl status >/dev/null; ctl status >/dev/null
    check "stable over the next ticks: still blocked, nothing repaired, no warnings" "blocked $w0 1" "$(route_of) $(grep -c 'WARN' "$WGS_DATA/logs/wg-shield.log") $(logn 'kill switch blocks traffic')"
    # a second network appears while blocked: captured as well
    ip link add rmnet5 type veth peer name rmnet5p && ip link set rmnet5p up && ip link set rmnet5 up
    ip addr add 10.66.0.2/24 dev rmnet5; ip route add default via 10.66.0.1 dev rmnet5 table 1035
    echo "1035 rmnet5" >> "$WGS_RT_TABLES"; echo "105 INTERNET&NOT_RESTRICTED&TRUSTED&VALIDATED" >> "$RUN/networks"
    ip rule add pref 16000 fwmark 0x10069/0x1ffff iif lo lookup 1035
    ctl status >/dev/null
    check "another internet network: blocked as well" blocked "$(ip route get 1.1.1.1 mark 0x10069 2>&1 | grep -q 'dev ' && echo open || echo blocked)"
    ip rule del pref 16000 fwmark 0x10069/0x1ffff iif lo lookup 1035
    ip link del rmnet5; sed -i '/^105 /d' "$RUN/networks"; sed -i '/^1035 /d' "$WGS_RT_TABLES"
    ctl status >/dev/null
    # leaving the block without leaving the error
    ctl set killswitch 0 >/dev/null
    check "kill switch off: direct in that tick, nothing left" "error wlan0 0 0" "$(st state) $(route_of) $(r4 5020) $(ip route show table 51820 2>/dev/null | grep -c .)"
    check "kill switch off: logged as direct again" 2 "$(logn 'state: error (tunnel_missing) - direct connection')"
    ctl set killswitch 1 >/dev/null
    check "kill switch on again: blocked" blocked "$(route_of)"
    ctl set ks_error 0 >/dev/null
    check "setting off: direct in that tick" "error wlan0 0" "$(st state) $(route_of) $(r4 5020)"
    ctl set ks_error 1 >/dev/null
    check "setting on again: blocked" blocked "$(route_of)"
    # pause and an Android VPN never block
    ctl pause 5 >/dev/null
    check "paused: direct" "paused wlan0 0" "$(st state) $(route_of) $(r4 5020)"
    ctl resume >/dev/null
    check "resumed: error and blocked again" "error blocked" "$(st state) $(route_of)"
    if [ "${WGS_UIDS:-}" = 1 ]; then
        ip rule add pref 13000 fwmark 0x0/0x20000 iif lo uidrange 10000-19999 lookup 1028
        ctl status >/dev/null
        check "an Android VPN: paused, direct" "paused android_vpn wlan0" "$(st state) $(st reason) $(route_of)"
        ip rule del pref 13000
        ctl status >/dev/null
        check "the Android VPN is gone: blocked again" "error blocked" "$(st state) $(route_of)"
    else
        echo "  skip Android VPN case (no --map-auto)"
    fi
    # leaving the error: the tunnel file is back
    cp "$RUN/ke1.conf" "$WGS_DATA/tunnels/wg-KE-1.conf"
    date +%s > "$STATE/fake_hs"; ctl status >/dev/null
    check "tunnel file back: up, through the tunnel, its endpoint rule" "up wgs0 1" "$(st state) $(route_of) $(ip rule | grep -c '^5000:.*to 203.0.113.92 ')"
    check "logged as up" 1 "$(tail -n 3 "$WGS_DATA/logs/wg-shield.log" | grep -c 'state: up - wg-KE-1')"
    # the file becomes invalid while the tunnel is up (the error comes from tunnel_ensure)
    sed -i 's#^Endpoint = .*#Endpoint = 999.1.1.1:51820#' "$WGS_DATA/tunnels/wg-KE-1.conf"
    ctl status >/dev/null
    check "invalid tunnel file: error, blocked, the old tunnel's interface and endpoint rule gone" "error blocked no 0 0" "$(st state) $(route_of) $(ip link show wgs0 >/dev/null 2>&1 && echo yes || echo no) $(r4 5000) $(nat | grep -c wgs_dns)"
    check "its reason in the log line" 1 "$(logn 'state: error (invalid_tunnel: .*) - kill switch blocks traffic')"
    ctl status >/dev/null
    check "still blocked at the next tick" "error blocked 1" "$(st state) $(route_of) $(r4 5020)"
    # another tunnel switched on
    ctl up wg-KE-2 >/dev/null
    check "another tunnel switched on: up, through it" "up wg-KE-2 wgs0 1" "$(st state) $(st tunnel) $(route_of) $(ip rule | grep -c '^5000:.*to 203.0.113.93 ')"
    # back to the broken one from the command line is refused; root edits the settings: error, blocked
    sed -i 's/^ACTIVE=.*/ACTIVE=wg-KE-1/' "$WGS_DATA/settings.conf"
    ctl status >/dev/null
    check "the broken tunnel active again: blocked, no endpoint rule of the other tunnel" "error blocked 0" "$(st state) $(route_of) $(r4 5000)"
    ctl down >/dev/null
    check "down: off, direct, nothing left" "off wlan0 0 0 0" "$(st state) $(route_of) $(r4 5020) $(r6 5020) $(ip route show table 51820 2>/dev/null | grep -c .)"
    # boot with a tunnel that cannot be built: the boot guard is kept
    sed -i 's/^ACTIVE=.*/ACTIVE=wg-KE-1/' "$WGS_DATA/settings.conf"
    $TSH "$MOD/post-fs-data.sh" >/dev/null 2>&1
    check "boot guard on" blocked "$(route_of)"
    ctl status >/dev/null
    check "first tick after boot: error, still blocked" "error blocked 1" "$(st state) $(route_of) $(st ks_error)"
    ctl set ks_error 0 >/dev/null
    $TSH "$MOD/post-fs-data.sh" >/dev/null 2>&1; ctl status >/dev/null
    check "the same boot with the setting off: direct after the first tick" "error wlan0" "$(st state) $(route_of)"
    ctl set ks_error 1 >/dev/null; ctl set killswitch 0 >/dev/null
    check "the setting on, the kill switch off: direct" "error wlan0 0" "$(st state) $(route_of) $(r4 5020)"
    ctl down >/dev/null
    check "lock released" no "$([ -d "$STATE/lock" ] && echo yes || echo no)"
fi

if want busybox_path; then
    echo "busybox_path: KernelSU, APatch and Magisk busybox are found"
    bbof() { env -u WGS_BB $TSH -c '. "$WGS_MODDIR/sh/common.sh"; echo "$BB"'; }
    rm -rf "$WGS_ADB/ksu" "$WGS_ADB/ap" "$WGS_ADB/magisk"
    mkdir -p "$WGS_ADB/magisk"; printf '#!/bin/sh\n' > "$WGS_ADB/magisk/busybox"; chmod 755 "$WGS_ADB/magisk/busybox"
    check "Magisk only" "$WGS_ADB/magisk/busybox" "$(bbof)"
    mkdir -p "$WGS_ADB/ap/bin"; cp "$WGS_ADB/magisk/busybox" "$WGS_ADB/ap/bin/busybox"
    check "APatch before Magisk" "$WGS_ADB/ap/bin/busybox" "$(bbof)"
    mkdir -p "$WGS_ADB/ksu/bin"; cp "$WGS_ADB/magisk/busybox" "$WGS_ADB/ksu/bin/busybox"
    check "KernelSU first" "$WGS_ADB/ksu/bin/busybox" "$(bbof)"
    rm -rf "$WGS_ADB/ksu" "$WGS_ADB/ap" "$WGS_ADB/magisk"
    check "none: the KernelSU path (as before)" "$WGS_ADB/ksu/bin/busybox" "$(bbof)"
fi

echo
echo "passed $PASS, failed $FAILN"
[ "$FAILN" = 0 ]
