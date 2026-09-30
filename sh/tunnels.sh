# WG Shield Arm64 - tunnel files (wg-quick format as exported by the WireGuard app)
# Private and preshared keys are never printed or logged.

# tun_parse FILE -> T_* variables, T_ERR empty when usable, T_WARN notes
tun_parse() {
    T_ADDR=""; T_EP=""; T_EPIP=""; T_MTU=1420; T_KA=""; T_ERR=""; T_WARN=""
    _ni=0; _np=0; _pk=0; _pub=0; _psk=0; T_ADDR6=""; T_V6=0; _addr=""; _mtu=""; _dns=0; _ign=""; _aips=""
    [ -f "$1" ] || { T_ERR="file not found"; return 1; }
    _out=$(tr -d '\r' 2>/dev/null < "$1" | awk '
    function trim(s) { gsub(/[ \t]/, "", s); return s }
    /^[ \t]*[#;]/ { next }
    /^[ \t]*\[/ {
        s = tolower(trim($0))
        if (s == "[interface]") { sec = "i"; ni++ } else if (s == "[peer]") { sec = "p"; np++ } else sec = "x"
        next
    }
    index($0, "=") > 0 {
        k = tolower(trim(substr($0, 1, index($0, "=") - 1)))
        v = trim(substr($0, index($0, "=") + 1))
        if (sec == "i") {
            if (k == "privatekey") pk = (length(v) == 44 && v ~ /^[A-Za-z0-9+\/]+=$/) ? 1 : (v == "" ? 0 : 2)
            else if (k == "address") addr = (addr == "" ? v : addr "," v)
            else if (k == "mtu") mtu = v
            else if (k == "dns") dns = 1
            else if (k == "table" || k == "preup" || k == "postup" || k == "predown" || k == "postdown" || k == "saveconfig") ign = ign " " k
        } else if (sec == "p") {
            if (k == "endpoint") ep = v
            else if (k == "allowedips") aips = (aips == "" ? v : aips "," v)
            else if (k == "persistentkeepalive") ka = v
            else if (k == "publickey") pub = (length(v) == 44 && v ~ /^[A-Za-z0-9+\/]+=$/) ? 1 : (v == "" ? 0 : 2)
            else if (k == "presharedkey") psk = (length(v) == 44 && v ~ /^[A-Za-z0-9+\/]+=$/) ? 1 : 2
        }
    }
    END {
        printf "PSK=%d\n", psk
        printf "NI=%d\nNP=%d\nPK=%d\nPUB=%d\nADDR=%s\nMTU=%s\nDNS=%d\nIGN=%s\nEP=%s\nAIPS=%s\nKA=%s\n", ni, np, pk, pub, addr, mtu, dns, ign, ep, aips, ka
    }')
    _oifs=$IFS; IFS='
'
    set -f
    for _l in $_out; do
        k=${_l%%=*}; v=${_l#*=}
        case "$k" in
            NI) _ni=$v ;; NP) _np=$v ;; PK) _pk=$v ;; PUB) _pub=$v ;; PSK) _psk=$v ;;
            ADDR) _addr=$v ;; MTU) _mtu=$v ;; DNS) _dns=$v ;; IGN) _ign=$v ;;
            EP) T_EP=$v ;; AIPS) _aips=$v ;; KA) T_KA=$v ;;
        esac
    done
    set +f
    IFS=$_oifs
    [ "$_ni" = 1 ] || { T_ERR="needs exactly one [Interface] section"; return 1; }
    [ "$_np" = 1 ] || { T_ERR="needs exactly one [Peer] section (found $_np)"; return 1; }
    case "$_pk" in 1) : ;; 0) T_ERR="no PrivateKey"; return 1 ;; *) T_ERR="PrivateKey is not a valid WireGuard key (44 characters ending in =)"; return 1 ;; esac
    case "$_pub" in 1) : ;; 0) T_ERR="no peer PublicKey"; return 1 ;; *) T_ERR="peer PublicKey is not a valid WireGuard key"; return 1 ;; esac
    [ "$_psk" = 2 ] && { T_ERR="PresharedKey is not a valid WireGuard key"; return 1; }
    for _a in $(echo "$_addr" | tr ',' ' '); do
        case "$_a" in *:*) [ -z "$T_ADDR6" ] && T_ADDR6=$_a ;; *) [ -z "$T_ADDR" ] && T_ADDR=$_a ;; esac
    done
    case "$T_ADDR" in
        "") T_ERR="no IPv4 Address"; return 1 ;;
        *[!0-9./]*) T_ERR="bad Address '$T_ADDR'"; return 1 ;;
        */*) : ;;
        *) T_ADDR="$T_ADDR/32" ;;
    esac
    # Endpoint: IPv4 literal, or a host name (resolved when the tunnel loads)
    T_EPIP=""; T_EPHOST=""; T_PORT=${T_EP##*:}; _h=${T_EP%:*}
    [ -n "$T_EP" ] && [ "$_h" != "$T_EP" ] || { T_ERR="Endpoint needs host:port (got '$T_EP')"; return 1; }
    case "$T_PORT" in ""|*[!0-9]*) T_ERR="Endpoint has no valid port (got '$T_EP')"; return 1 ;; esac
    case "$_h" in
        "") T_ERR="Endpoint has no host"; return 1 ;;
        *[!0-9.]*)
            case "$_h" in
                *[!A-Za-z0-9.-]*|.*|*.|*..*|-*) T_ERR="Endpoint must be an IPv4 address or a host name (got '$T_EP')"; return 1 ;;
                *.*) T_EPHOST=$_h ;;
                *) T_ERR="Endpoint host name has no domain (got '$T_EP')"; return 1 ;;
            esac ;;
        *) T_EPIP=$_h ;;
    esac
    case ",$_aips," in *,0.0.0.0/0,*) : ;; *) T_ERR="AllowedIPs must include 0.0.0.0/0 (full tunnel)"; return 1 ;; esac
    # IPv6 through the tunnel: an IPv6 address and ::/0
    if [ -n "$T_ADDR6" ]; then
        case "$T_ADDR6" in *[!0-9A-Fa-f:/]*) T_WARN="$T_WARN bad-IPv6-address-ignored"; T_ADDR6="" ;; */*) : ;; *) T_ADDR6="$T_ADDR6/128" ;; esac
    fi
    case ",$_aips," in *,::/0,*) [ -n "$T_ADDR6" ] && T_V6=1 ;; esac
    [ -n "$T_ADDR6" ] && [ "$T_V6" = 0 ] && T_WARN="$T_WARN IPv6-address-without-::/0-ignored"
    case "$_mtu" in "") : ;; *[!0-9]*) T_WARN="$T_WARN bad-MTU-ignored" ;;
        *) if [ "$_mtu" -ge 1280 ] && [ "$_mtu" -le 1500 ]; then T_MTU=$_mtu; else T_WARN="$T_WARN MTU-out-of-range-ignored"; fi ;;
    esac
    [ "$_dns" = 1 ] && T_WARN="$T_WARN DNS-ignored(dns-is-left-to-the-system/dnscrypt-proxy)"
    [ -n "$T_EPHOST" ] && T_WARN="$T_WARN host-name-endpoint(resolved-at-connect)"
    [ -n "$_ign" ] && T_WARN="$T_WARN ignored:$(echo $_ign | tr ' ' ',')"
    [ -z "$T_KA" ] && T_WARN="$T_WARN no-PersistentKeepalive(25-is-used)"
    T_WARN=${T_WARN# }
    return 0
}

# tun_setconf SRC DST [ENDPOINT] - keep only WireGuard keys (like wg-quick strip);
# add PersistentKeepalive = 25 when the peer has none (health needs regular handshakes);
# ENDPOINT replaces a host-name endpoint with the resolved address
tun_setconf() {
    umask 077
    tr -d '\r' 2>/dev/null < "$1" | awk -v addka="$( [ -z "$T_KA" ] && echo 1 || echo 0 )" -v ep="$3" '
        {
            line = $0; k = line
            if (index(k, "=") > 0) { k = substr(k, 1, index(k, "=") - 1); gsub(/[ \t]/, "", k); k = tolower(k) }
            if (k == "endpoint" && ep != "") { print "Endpoint = " ep; next }
            if (k == "address" || k == "dns" || k == "mtu" || k == "table" || k == "preup" || k == "postup" || k == "predown" || k == "postdown" || k == "saveconfig") next
            print line
            h = line; gsub(/[ \t]/, "", h)
            if (tolower(h) == "[peer]" && addka == "1") print "PersistentKeepalive = 25"
        }' > "$2"
}

tun_file() { echo "$TUNDIR/$1.conf"; }

tun_exists() { tunnel_name_ok "$1" && [ -f "$TUNDIR/$1.conf" ]; }

tun_names() {
    for f in "$TUNDIR"/*.conf; do
        [ -f "$f" ] || continue
        n=${f##*/}; echo "${n%.conf}"
    done
}

# tun_import_one FILE -> prints result line, returns 0 imported / 1 skipped
tun_import_one() {
    src=$1
    base=${src##*/}; base=${base%.conf}
    name=$(printf '%s' "$base" | sed 's/[^A-Za-z0-9._-]/_/g' | cut -c1-40)
    case "$name" in .*|"") name="tunnel_$name" ;; esac
    if ! tun_parse "$src"; then
        echo "skipped=$base reason=$T_ERR"
        wlog WARN "import: $base skipped - $T_ERR"
        return 1
    fi
    dst="$TUNDIR/$name.conf"
    what=imported; [ -f "$dst" ] && what=replaced
    umask 077
    cp -f "$src" "$dst.tmp.$$" && chmod 600 "$dst.tmp.$$" && mv -f "$dst.tmp.$$" "$dst" || { echo "skipped=$base reason=cannot-write"; return 1; }
    echo "$what=$name endpoint=$T_EP${T_WARN:+ notes=$(echo "$T_WARN" | tr ' ' ';')}"
    wlog INFO "tunnel $name $what (endpoint $T_EP)${T_WARN:+ - notes: $T_WARN}"
    return 0
}

# tun_import PATH (.zip export from the WireGuard app, or one .conf)
tun_import() {
    p=$1; ok=0; bad=0
    [ -f "$p" ] || { echo "ok=0"; echo "error=file not found: $p"; return 1; }
    mkdir -p "$TUNDIR"; chmod 700 "$DATA" "$TUNDIR"
    case "$p" in
        *.zip|*.ZIP)
            tmp="$STATE/import.$$"; rm -rf "$tmp"; mkdir -p "$tmp"; chmod 700 "$tmp"
            if [ -x "$BB" ]; then "$BB" unzip -o -q "$p" -d "$tmp" >/dev/null 2>&1; else unzip -o -q "$p" -d "$tmp" >/dev/null 2>&1; fi
            found=0
            for f in $(find "$tmp" -type f -name '*.conf' 2>/dev/null | sort); do
                found=1
                if tun_import_one "$f"; then ok=$((ok + 1)); else bad=$((bad + 1)); fi
            done
            rm -rf "$tmp"
            [ "$found" = 1 ] || { echo "ok=0"; echo "error=no .conf files in $p"; return 1; }
            ;;
        *)
            if tun_import_one "$p"; then ok=1; else bad=1; fi
            ;;
    esac
    [ "$ok" -gt 0 ] && echo "ok=1" || echo "ok=0"
    echo "imported=$ok"
    echo "skipped=$bad"
    [ "$ok" -gt 0 ]
}
