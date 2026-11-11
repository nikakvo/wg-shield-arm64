# WG Shield Arm64 - tunnel files (wg-quick format as exported by the WireGuard
# or AmneziaWG app). Private, preshared and header protection keys are never
# printed or logged.
#
# Tunnel type: a config with any AmneziaWG key is an AmneziaWG tunnel
# (T_TYPE=amneziawg), otherwise plain WireGuard (T_TYPE=wireguard). The AWG
# keys are those of amneziawg-tools 3.1 (config.c): Jc Jmin Jmax S1-S4 H1-H4
# I1-I5 HeaderProtectionKey ContentPaddingAddition RandomTrailers
# DisableCookies KeepaliveTimeout MaxHandshakeAttempts RejectAfterTime
# RekeyAfterTime RekeyTimeout ([Interface]) and AdvancedSecurity ([Peer]).
# Their values go to `awg setconf` unchanged - it checks them (formats differ
# between AWG versions); only HeaderProtectionKey is checked here, as a key.

# tun_parse FILE -> T_* variables, T_ERR empty when usable, T_WARN notes
tun_parse() {
    T_ADDR=""; T_EP=""; T_EPIP=""; T_MTU=1420; T_KA=""; T_ERR=""; T_WARN=""; T_TYPE=wireguard; _awg=0; _hpk=0
    _ni=0; _np=0; _pk=0; _pub=0; _psk=0; T_ADDR6=""; T_V6=0; _addr=""; _mtu=""; _dns=""; _ign=""; _aips=""; T_DNS=""; T_DNS6=""; T_DNSALL=""
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
            else if (k == "dns") dns = (dns == "" ? v : dns "," v)
            else if (k == "table" || k == "preup" || k == "postup" || k == "predown" || k == "postdown" || k == "saveconfig") ign = ign " " k
            else if (k == "headerprotectionkey") { awg = 1; hpk = (length(v) == 44 && v ~ /^[A-Za-z0-9+\/]+=$/) ? 1 : 2 }
            else if (k ~ /^(jc|jmin|jmax|s[1-4]|h[1-4]|i[1-5]|contentpaddingaddition|randomtrailers|disablecookies|keepalivetimeout|maxhandshakeattempts|rejectaftertime|rekeyaftertime|rekeytimeout)$/) awg = 1
        } else if (sec == "p") {
            if (k == "endpoint") ep = v
            else if (k == "allowedips") aips = (aips == "" ? v : aips "," v)
            else if (k == "persistentkeepalive") ka = v
            else if (k == "publickey") pub = (length(v) == 44 && v ~ /^[A-Za-z0-9+\/]+=$/) ? 1 : (v == "" ? 0 : 2)
            else if (k == "presharedkey") psk = (length(v) == 44 && v ~ /^[A-Za-z0-9+\/]+=$/) ? 1 : 2
            else if (k == "advancedsecurity") awg = 1
        }
    }
    END {
        printf "PSK=%d\nAWG=%d\nHPK=%d\n", psk, awg, hpk
        printf "NI=%d\nNP=%d\nPK=%d\nPUB=%d\nADDR=%s\nMTU=%s\nDNS=%s\nIGN=%s\nEP=%s\nAIPS=%s\nKA=%s\n", ni, np, pk, pub, addr, mtu, dns, ign, ep, aips, ka
    }')
    _oifs=$IFS; IFS='
'
    set -f
    for _l in $_out; do
        k=${_l%%=*}; v=${_l#*=}
        case "$k" in
            NI) _ni=$v ;; NP) _np=$v ;; PK) _pk=$v ;; PUB) _pub=$v ;; PSK) _psk=$v ;; AWG) _awg=$v ;; HPK) _hpk=$v ;;
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
    [ "$_hpk" = 2 ] && { T_ERR="HeaderProtectionKey is not a valid key (44 characters ending in =)"; return 1; }
    [ "$_awg" = 1 ] && T_TYPE=amneziawg
    for _a in $(echo "$_addr" | tr ',' ' '); do
        case "$_a" in *:*) [ -z "$T_ADDR6" ] && T_ADDR6=$_a ;; *) [ -z "$T_ADDR" ] && T_ADDR=$_a ;; esac
    done
    case "$T_ADDR" in
        "") T_ERR="no IPv4 Address"; return 1 ;;
        *[!0-9./]*) T_ERR="bad Address '$T_ADDR'"; return 1 ;;
        */*) : ;;
        *) T_ADDR="$T_ADDR/32" ;;
    esac
    _pl=${T_ADDR#*/}
    ipv4_ok "${T_ADDR%%/*}" && case "$_pl" in ""|*[!0-9]*) false ;; *) [ "${#_pl}" -le 2 ] && [ "$_pl" -le 32 ] ;; esac ||
        { T_ERR="bad Address '$T_ADDR'"; return 1; }
    # Endpoint: IPv4 literal, an IPv6 literal in brackets, or a host name
    # (resolved when the tunnel loads, to an IPv4 address). T_EPIP of an IPv6
    # endpoint is the address as the kernel lists it (ipv6_canon): it is
    # compared with `ip -6 rule` output; wg gets the file's own line
    T_EPIP=""; T_EPHOST=""; T_PORT=${T_EP##*:}; _h=${T_EP%:*}
    [ -n "$T_EP" ] && [ "$_h" != "$T_EP" ] || { T_ERR="Endpoint needs host:port (got '$T_EP')"; return 1; }
    case "$T_PORT" in
        ""|*[!0-9]*) T_ERR="Endpoint has no valid port (got '$T_EP')"; return 1 ;;
        *) [ "${#T_PORT}" -le 5 ] && [ "$T_PORT" -ge 1 ] && [ "$T_PORT" -le 65535 ] ||
               { T_ERR="Endpoint port must be 1-65535 (got '$T_EP')"; return 1; } ;;
    esac
    case "$_h" in
        "") T_ERR="Endpoint has no host"; return 1 ;;
        "["*"]")
            _h=${_h#"["}; _h=${_h%"]"}
            T_EPIP=$(ipv6_canon "$_h") && [ -n "$T_EPIP" ] ||
                { T_EPIP=""; T_ERR="Endpoint is not a usable IPv6 address (got '$T_EP')"; return 1; } ;;
        *[!0-9.]*)
            case "$_h" in
                *[!A-Za-z0-9.-]*|.*|*.|*..*|-*) T_ERR="Endpoint must be an IPv4 address or a host name (got '$T_EP')"; return 1 ;;
                *.*) T_EPHOST=$_h ;;
                *) T_ERR="Endpoint host name has no domain (got '$T_EP')"; return 1 ;;
            esac ;;
        *) ipv4_ok "$_h" || { T_ERR="Endpoint is not a valid IPv4 address (got '$T_EP')"; return 1; }
           T_EPIP=$_h ;;
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
    # DNS: the first IPv4 server is used while the tunnel is on, the first
    # IPv6 server while it carries IPv6 too (sh/net.sh dns_ensure); search
    # domains are not used. T_DNSALL: every IPv4 server in the line's order -
    # the next one takes over when the active one stops answering (sh/recover.sh
    # dns_fo_check)
    for _d in $(echo "$_dns" | tr ',' ' '); do
        if ipv4_ok "$_d"; then
            [ -z "$T_DNS" ] && T_DNS=$_d
            case " $T_DNSALL " in *" $_d "*) : ;; *) T_DNSALL="$T_DNSALL${T_DNSALL:+ }$_d" ;; esac
        else
            case "$_d" in *:*:*) case "$_d" in *[!0-9A-Fa-f:]*|*:::*) : ;; *) [ -z "$T_DNS6" ] && [ "${#_d}" -le 39 ] && T_DNS6=$_d ;; esac ;; esac
        fi
    done
    [ -n "$_dns" ] && [ -z "$T_DNS" ] && T_WARN="$T_WARN DNS-without-IPv4-ignored"
    [ -n "$T_EPHOST" ] && T_WARN="$T_WARN host-name-endpoint(resolved-at-connect)"
    case "$T_EPIP" in *:*) T_WARN="$T_WARN IPv6-endpoint(the-network-needs-IPv6)" ;; esac
    [ -n "$_ign" ] && T_WARN="$T_WARN ignored:$(echo $_ign | tr ' ' ',')"
    [ -z "$T_KA" ] && T_WARN="$T_WARN no-PersistentKeepalive(25-is-used)"
    if [ "$T_TYPE" = amneziawg ]; then
        T_WARN="$T_WARN AmneziaWG"
        awg_kernel_ok || T_WARN="$T_WARN AmneziaWG-is-not-in-this-kernel(the-tunnel-cannot-start-here)"
    fi
    T_WARN=${T_WARN# }
    return 0
}

# tun_setconf SRC DST [ENDPOINT] - keep only WireGuard / AmneziaWG keys (like
# wg-quick strip); add PersistentKeepalive = 25 when the peer has none (health
# needs regular handshakes); ENDPOINT replaces a host-name endpoint with the
# resolved address. Lines start at column 0: awg keeps the spaces inside
# I1-I5 only when the line begins with the key.
tun_setconf() {
    umask 077
    tr -d '\r' 2>/dev/null < "$1" | awk -v addka="$( [ -z "$T_KA" ] && echo 1 || echo 0 )" -v ep="$3" '
        {
            line = $0; sub(/^[ \t]+/, "", line); k = line
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

# ---- favorites (2.4) ---------------------------------------------------------
# $FAVS: one tunnel name per line, only valid names count (a hand-edited
# file can not inject anything into the poll rows), 0600 like the settings.
fav_names() {
    [ -f "$FAVS" ] || return 0
    while IFS= read -r _fn; do
        _fn=$(printf '%s' "$_fn" | tr -d '\r')
        tunnel_name_ok "$_fn" && echo "$_fn"
    done < "$FAVS" 2>/dev/null | sort -u
}
fav_has() { fav_names | grep -qxF "$1"; }
_fav_write() {  # names on stdin -> $FAVS (removed when empty)
    _ft="$FAVS.tmp.$$"
    sort -u > "$_ft" && chmod 600 "$_ft" || { rm -f "$_ft"; return 1; }
    if [ -s "$_ft" ]; then mv -f "$_ft" "$FAVS"; else rm -f "$_ft" "$FAVS"; fi
}
fav_add() { { fav_names; echo "$1"; } | _fav_write; }
fav_del() { fav_names | grep -vxF "$1" | _fav_write; }

# ---- backup (2.6) -------------------------------------------------------------
# One zip, like the WireGuard app's export: <name>.conf per tunnel +
# favorites.txt + backup-info.txt. Neither busybox nor toybox can create a zip,
# so zip_store writes one itself (entries stored, not compressed - the files
# are a few hundred bytes); the CRC-32 of each file comes from gzip, whose
# last 8 bytes are CRC-32 + size. The new zip is written as a temp file,
# unpacked again and compared file by file, and only then renamed over the
# old one - a failed or damaged backup never replaces a good one.
_bk_unzip() { if [ -x "$BB" ]; then "$BB" unzip "$@"; else unzip "$@"; fi; }
_bk_gzip() { if [ -x "$BB" ]; then "$BB" gzip -c; else gzip -c; fi; }

# _le VALUE BYTES - appends the printf escapes of a little-endian number to
# $_F (no subshell: mksh forks for every $(...), 80 tunnels took 12 s that way)
_le() {
    _lv=$1; _ln=$2
    while [ "$_ln" -gt 0 ]; do
        _lb=$((_lv & 255))
        # byte 37 is "%": some printf (coreutils) read an escaped \045 as the
        # start of a conversion, so it is written as %% instead
        if [ "$_lb" = 37 ]; then _F="$_F%%"; else _F="$_F\\$((_lb >> 6 & 7))$((_lb >> 3 & 7))$((_lb & 7))"; fi
        _lv=$((_lv >> 8)); _ln=$((_ln - 1))
    done
}

# zip_store OUT DIR NAME... - stored zip of DIR/NAME files (names: [A-Za-z0-9._-])
zip_store() {
    _zo=$1; _zd=$2; shift 2
    _zl="$_zo.list"; : > "$_zo" || return 1; : > "$_zl"
    set -- $(date '+%Y %m %d %H %M %S') "$@"
    _zY=$1; _zM=${2#0}; _zD=${3#0}; _zh=${4#0}; _zm=${5#0}; _zs=${6#0}; shift 6
    _F=""; _le $(( (_zh << 11) | (_zm << 5) | (_zs / 2) )) 2; _le $(( ((_zY - 1980) << 9) | (_zM << 5) | _zD )) 2
    _zdt=$_F   # DOS time + date, the same for every entry
    _zoff=0; _zn=0
    for _zf in "$@"; do
        _zp="$_zd/$_zf"
        _zsz=$(wc -c < "$_zp") || return 1; _zsz=$((_zsz + 0))
        # gzip trailer: CRC-32 (4 bytes, little-endian) then the size
        set -- $(_bk_gzip < "$_zp" | tail -c 8 | od -An -tu1)
        [ $# = 8 ] || return 1
        _F=""; _le "$1" 1; _le "$2" 1; _le "$3" 1; _le "$4" 1; _zc=$_F
        _znl=${#_zf}
        _F='\120\113\003\004\024\000\000\000\000\000'"$_zdt$_zc"; _le $_zsz 4; _le $_zsz 4; _le $_znl 2; _F="$_F\\000\\000"
        { printf "$_F"; printf '%s' "$_zf"; cat "$_zp"; } >> "$_zo" || return 1
        printf '%s\n' "$_zf|$_zc|$_zsz|$_zoff" >> "$_zl"   # not echo: mksh's echo reads the backslashes
        _zoff=$((_zoff + 30 + _znl + _zsz)); _zn=$((_zn + 1))
    done
    _zcd=$_zoff
    while IFS='|' read -r _zf _zc _zsz _zfo; do
        _F='\120\113\001\002\024\000\024\000\000\000\000\000'"$_zdt$_zc"; _le $_zsz 4; _le $_zsz 4; _le ${#_zf} 2
        _F="$_F"'\000\000\000\000\000\000\000\000\000\000\000\000'; _le $_zfo 4
        { printf "$_F"; printf '%s' "$_zf"; } >> "$_zo" || return 1
        _zoff=$((_zoff + 46 + ${#_zf}))
    done < "$_zl"
    _F='\120\113\005\006\000\000\000\000'; _le $_zn 2; _le $_zn 2; _le $((_zoff - _zcd)) 4; _le $_zcd 4; _F="$_F\\000\\000"
    printf "$_F" >> "$_zo" || return 1
    rm -f "$_zl"
}

bk_fix() {  # leftovers: an interrupted backup, the folder of 2.6-test1
    rm -f "$BACKUP_ROOT/.wg-shield-backup.zip.tmp" "$BACKUP_ROOT/.wg-shield-backup.zip.tmp.list" 2>/dev/null
}
bk_count() { if [ -f "$BKZIP" ]; then _bk_unzip -l "$BKZIP" 2>/dev/null | grep -cE '\.conf$'; else echo 0; fi; }
bk_created() { _bk_unzip -p "$BKZIP" backup-info.txt 2>/dev/null | sed -n 's/^created_epoch=//p' | head -n 1; }
bk_favs() { _bk_unzip -p "$BKZIP" favorites.txt 2>/dev/null | grep -c .; }

# bk_make - prints backed_up=N; returns 1 (with error=) when nothing was written
bk_make() {
    _bn=0; for _bf in "$TUNDIR"/*.conf; do [ -f "$_bf" ] && _bn=$((_bn + 1)); done
    [ "$_bn" -gt 0 ] || { echo "error=no tunnels to back up"; return 1; }
    bk_fix
    mkdir -p "$BACKUP_ROOT" 2>/dev/null || { echo "error=cannot create $BACKUP_ROOT"; return 1; }
    _bs="$STATE/bk.$$"; rm -rf "$_bs"; mkdir -p "$_bs"; chmod 700 "$_bs"
    for _bf in "$TUNDIR"/*.conf; do [ -f "$_bf" ] && cp -f "$_bf" "$_bs/"; done
    fav_names > "$_bs/favorites.txt"
    _bnow=$(date +%s)
    { echo "WG Shield backup - $_bn tunnels, $(date '+%Y-%m-%d %H:%M')"
      echo "The .conf files hold private keys. Restore: WG Shield WebUI -> Tunnels -> Backup -> Restore,"
      echo "or import this zip in the WireGuard / AmneziaWG app."
      echo "created_epoch=$_bnow"
      echo "tunnels=$_bn"; } > "$_bs/backup-info.txt"
    _bl=$(cd "$_bs" && ls *.conf | sort); [ -s "$_bs/favorites.txt" ] && _bl="$_bl favorites.txt"
    _bt="$BACKUP_ROOT/.wg-shield-backup.zip.tmp"
    if ! zip_store "$_bt" "$_bs" $_bl backup-info.txt; then
        rm -rf "$_bs"; bk_fix; echo "error=cannot write $BACKUP_ROOT (storage full?)"; return 1
    fi
    # check: unpack the new zip and compare every file
    _bv="$STATE/bkv.$$"; rm -rf "$_bv"; mkdir -p "$_bv"; chmod 700 "$_bv"
    _bok=1
    _bk_unzip -o -q "$_bt" -d "$_bv" >/dev/null 2>&1 || _bok=0
    for _bf in $_bl backup-info.txt; do cmp -s "$_bs/$_bf" "$_bv/$_bf" || { _bok=0; break; }; done
    rm -rf "$_bs" "$_bv"
    [ "$_bok" = 1 ] || { bk_fix; echo "error=the new backup did not check out - the old one is kept"; return 1; }
    mv -f "$_bt" "$BKZIP" || { bk_fix; echo "error=cannot replace the old backup"; return 1; }
    rm -rf "$BACKUP_ROOT/backup"   # the folder of 2.6-test1
    echo "backed_up=$_bn"
}

# bk_restore - imports every .conf of the backup (same name = replaced, other
# tunnels stay) and gives the backed-up favorites their star again
bk_restore() {
    bk_fix
    [ "$(bk_count)" -gt 0 ] || { echo "error=no backup in $BACKUP_ROOT"; return 1; }
    mkdir -p "$TUNDIR"; chmod 700 "$DATA" "$TUNDIR"
    _br="$STATE/restore.$$"; rm -rf "$_br"; mkdir -p "$_br"; chmod 700 "$_br"
    _bk_unzip -o -q "$BKZIP" -d "$_br" >/dev/null 2>&1
    _br_ok=0; _br_bad=0; _br_names=""
    # one file per line: names with spaces stay whole, nothing is globbed
    _br_ifs=$IFS; IFS='
'
    set -f
    for _bf in $(find "$_br" -type f -name '*.conf' 2>/dev/null | sort); do
        IFS=$_br_ifs; set +f
        if tun_import_one "$_bf"; then _br_ok=$((_br_ok + 1)); _br_names="$_br_names $name"; else _br_bad=$((_br_bad + 1)); fi
    done
    IFS=$_br_ifs; set +f
    _br_fav=0
    if [ -f "$_br/favorites.txt" ]; then
        _br_list=$(tr -d '\r' < "$_br/favorites.txt" | while IFS= read -r _fn; do
            tunnel_name_ok "$_fn" || continue
            case " $_br_names " in *" $_fn "*) echo "$_fn" ;; esac
        done)
        if [ -n "$_br_list" ]; then
            { fav_names; echo "$_br_list"; } | _fav_write
            _br_fav=$(echo "$_br_list" | grep -c .)
        fi
    fi
    rm -rf "$_br"
    echo "imported=$_br_ok"; echo "skipped=$_br_bad"; echo "favorites=$_br_fav"
    [ "$_br_ok" -gt 0 ]
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
    echo "$what=$name endpoint=$T_EP type=$T_TYPE${T_WARN:+ notes=$(echo "$T_WARN" | tr ' ' ';')}"
    wlog INFO "tunnel $name $what (endpoint $T_EP, $T_TYPE)${T_WARN:+ - notes: $T_WARN}"
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
            # one file per line: names with spaces stay whole, nothing is globbed
            _ti_ifs=$IFS; IFS='
'
            set -f
            for f in $(find "$tmp" -type f -name '*.conf' 2>/dev/null | sort); do
                IFS=$_ti_ifs; set +f
                found=1
                if tun_import_one "$f"; then ok=$((ok + 1)); else bad=$((bad + 1)); fi
            done
            IFS=$_ti_ifs; set +f
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
