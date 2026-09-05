#!/bin/sh
# deploy-openwrt-yggdrasil.sh — automated deployment of the routed Yggdrasil /64
# design documented in this repository (README.md / QUICKSTART.md / REFERENCE_CONFIG.md).
#
# Runs ON the OpenWrt router, under BusyBox ash. POSIX sh only.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:
#   deploy-openwrt-yggdrasil.sh --peer tls://host:port [--peer ...] [options]
#   ssh root@router sh -s -- --peer tls://host:port < deploy-openwrt-yggdrasil.sh
#
# The peer list is the only mandatory input. Everything else has a tested default.

set -u

VERSION='1.2.0'
SELF="${0##*/}"

# ---------------------------------------------------------------- defaults ---

IFACE='ygg0'
LAN='lan'
PEERS=''
PEERS_MODE='replace'          # replace | add
TRUSTED=''
DO_JUMPER=1
DO_LAN=1
DO_FIREWALL=1
DO_STATUS=1
DO_MULTICAST=1
# Part III is a separate module in the design — the routed /64, SLAAC, the
# firewall policy and the status page all work without it — but a deployment
# that stops short of it is not finished, so it runs unless --no-dns says not to.
DO_DNS=1
DNS_DOMAIN='home.arpa'
DNS_ROUTER='router'
DNS_HOSTS=''
STATUS_PKG=''
STATUS_BASE='https://raw.githubusercontent.com/Plasmoid77/Yggdrasil-OpenWRT/main/packages'
STATUS_URL=''
# Newest first. v5.1 fixes the prefix-class lookup; v5 only resolves the routed
# /64 when the Yggdrasil interface happens to be named 'ygg'.
STATUS_VERSIONS='yggdrasil-status-v5.1 yggdrasil-status-v5'
PRIVATE_KEY_FILE=''
SUPPLIED_KEY=''
DRY_RUN=0
ASSUME_YES=0
WAIT_SECS=90
BACKUP_DIR=''

# ------------------------------------------------------------------ output ---

RC_OK=0
FAILED_STAGE=''
CHANGED_NETWORK=0
CHANGED_DHCP=0
CHANGED_FIREWALL=0

# Colour only on a real terminal, so a redirected log stays plain text.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    _e="$(printf '\033')"
    C_RST="${_e}[0m"; C_DIM="${_e}[2m"; C_BLD="${_e}[1m"
    C_OK="${_e}[32m"; C_WRN="${_e}[33m"; C_ERR="${_e}[31m"; C_HDR="${_e}[36m"
else
    C_RST=''; C_DIM=''; C_BLD=''; C_OK=''; C_WRN=''; C_ERR=''; C_HDR=''
fi

RULE='------------------------------------------------------------'

info()  { printf '%s  ·%s %s\n' "$C_DIM" "$C_RST" "$*" >&2; }
ok()    { printf '%s  ok%s %s\n' "$C_OK" "$C_RST" "$*" >&2; }
warn()  { printf '%s  !!%s %s\n' "$C_WRN" "$C_RST" "$*" >&2; }
err()   { printf '%s  EE%s %s\n' "$C_ERR" "$C_RST" "$*" >&2; }
step()  { printf '\n%s%s\n %s\n%s%s\n' "$C_HDR" "$RULE" "$*" "$RULE" "$C_RST" >&2; }
banner() {
    printf '\n%s%s\n' "$C_HDR" "$RULE" >&2
    printf ' %s\n' "$*" >&2
    printf '%s%s\n' "$RULE" "$C_RST" >&2
}

die() {
    err "$*"
    [ -n "$FAILED_STAGE" ] && err "failed during stage: $FAILED_STAGE"
    rollback
    exit 1
}

usage() {
    cat >&2 <<USAGE
$SELF $VERSION — deploy routed Yggdrasil /64 on OpenWrt

Required:
  --peer URI            Public peer to configure. Repeatable.
                        Schemes: tls tcp quic ws wss socks sockstls
  --peers-file FILE     Read peers from FILE, one URI per line (# = comment).

Peer handling:
  --add-peers           Append to existing peers instead of replacing the set.

Node identity:
  --private-key-file F  Restore an existing Yggdrasil identity from file F,
                        keeping its node address. F holds the 128 hex character
                        private key and nothing else. The key may also be passed
                        in the YGG_PRIVATE_KEY environment variable. It is never
                        accepted as an argument value: /proc/<pid>/cmdline is
                        world readable. Without either, an existing key in the
                        configuration is kept and a missing one is generated.

Trusted remote access (firewall src_ip allow-list):
  --trusted ADDR        Yggdrasil /128 allowed to reach the router and LAN.
                        Repeatable. Without any, the ygg zone stays fully closed.

DNS module (Part III, on by default — see also --no-dns):
  --dns-domain NAME     Private namespace (default: $DNS_DOMAIN)
  --dns-router NAME     Hostname for this router (default: $DNS_ROUTER)
  --dns-host NAME=ADDR  Extra record. Repeatable; repeat a NAME to give it
                        several addresses.

Scope:
  --iface NAME          Yggdrasil interface / UCI section name (default: $IFACE)
  --lan NAME            LAN UCI interface name (default: $LAN)
  --no-jumper           Do not install/enable yggdrasil-jumper
  --no-multicast        Do not enable LAN multicast peering
  --no-lan              Do not touch LAN ip6assign/ip6class/RA/SLAAC
  --no-firewall         Do not create the ygg zone or trusted rules
  --no-status           Do not install the LuCI status module
  --no-dns              Do not serve <name>.$DNS_DOMAIN over Yggdrasil
  --status-pkg PATH     Install the status module from a local tarball
  --status-url URL      Override the status module download URL

Behaviour:
  -n, --dry-run         Print what would change; touch nothing
  -y, --yes             Non-interactive; do not prompt before applying
  --wait SECONDS        Seconds to wait for the Ygg prefix (default: $WAIT_SECS)
  -h, --help            This text
USAGE
}

# -------------------------------------------------------------- arg parsing ---

add_peer() {
    _p="$1"
    case "$_p" in
        tls://*|tcp://*|quic://*|ws://*|wss://*|socks://*|sockstls://*) : ;;
        *) die "unsupported peer URI (bad scheme): $_p" ;;
    esac
    case "$_p" in
        *' '*|*"$(printf '\t')"*) die "peer URI contains whitespace: $_p" ;;
    esac
    PEERS="${PEERS}${PEERS:+
}$_p"
}

add_trusted() {
    _t="$1"
    case "$_t" in
        2??:*|3??:*) : ;;
        *) die "trusted address does not look like a Yggdrasil 200::/7 address: $_t" ;;
    esac
    # tolerate a repeated address instead of writing a duplicate src_ip
    if printf '%s\n' "$TRUSTED" | grep -qxF "$_t"; then return 0; fi
    case "$_t" in
        */*) die "trusted address must be a bare /128 address, no prefix length: $_t" ;;
    esac
    TRUSTED="${TRUSTED}${TRUSTED:+
}$_t"
}

add_dns_host() {
    case "$1" in
        *=*) : ;;
        *)   die "--dns-host expects NAME=ADDRESS: $1" ;;
    esac
    _n="${1%%=*}"
    _a="${1#*=}"
    [ -n "$_n" ] || die "--dns-host: empty hostname in '$1'"
    case "$_n" in
        *.*) die "--dns-host: give a bare hostname, the domain is appended: $_n" ;;
    esac
    case "$_a" in
        2??:*|3??:*) : ;;
        *) die "--dns-host: '$_a' is not a Yggdrasil 200::/7 address" ;;
    esac
    DNS_HOSTS="${DNS_HOSTS}${DNS_HOSTS:+
}$_n=$_a"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --peer)        [ $# -ge 2 ] || die "--peer needs a value";        add_peer "$2";    shift 2 ;;
        --peers-file)  [ $# -ge 2 ] || die "--peers-file needs a value"
                       [ -r "$2" ]  || die "cannot read peers file: $2"
                       while IFS= read -r _line || [ -n "$_line" ]; do
                           _line="${_line%%#*}"
                           _line="$(printf '%s' "$_line" | tr -d ' \t\r')"
                           [ -n "$_line" ] && add_peer "$_line"
                       done < "$2"
                       shift 2 ;;
        --add-peers)   PEERS_MODE='add';   shift ;;
        --trusted)     [ $# -ge 2 ] || die "--trusted needs a value";     add_trusted "$2"; shift 2 ;;
        --private-key-file)
                       [ $# -ge 2 ] || die "--private-key-file needs a value"
                       PRIVATE_KEY_FILE="$2"; shift 2 ;;
        --iface)       [ $# -ge 2 ] || die "--iface needs a value";       IFACE="$2";       shift 2 ;;
        --lan)         [ $# -ge 2 ] || die "--lan needs a value";         LAN="$2";         shift 2 ;;
        --no-jumper)   DO_JUMPER=0;        shift ;;
        --no-multicast) DO_MULTICAST=0;    shift ;;
        --no-lan)      DO_LAN=0;           shift ;;
        --no-firewall) DO_FIREWALL=0;      shift ;;
        --no-status)   DO_STATUS=0;        shift ;;
        --dns)         DO_DNS=1;           shift ;;
        --no-dns)      DO_DNS=0;           shift ;;
        --dns-domain)  [ $# -ge 2 ] || die "--dns-domain needs a value";  DNS_DOMAIN="$2";  shift 2 ;;
        --dns-router)  [ $# -ge 2 ] || die "--dns-router needs a value";  DNS_ROUTER="$2";  shift 2 ;;
        --dns-host)    [ $# -ge 2 ] || die "--dns-host needs a value";    add_dns_host "$2"; shift 2 ;;
        --status-pkg)  [ $# -ge 2 ] || die "--status-pkg needs a value";  STATUS_PKG="$2";  shift 2 ;;
        --status-url)  [ $# -ge 2 ] || die "--status-url needs a value";  STATUS_URL="$2";  shift 2 ;;
        --wait)        [ $# -ge 2 ] || die "--wait needs a value";        WAIT_SECS="$2";   shift 2 ;;
        -n|--dry-run)  DRY_RUN=1;          shift ;;
        -y|--yes)      ASSUME_YES=1;       shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage; die "unknown argument: $1" ;;
    esac
done

[ -n "$PEERS" ] || { usage; die "no peers given; --peer or --peers-file is required"; }

# Ask for the Yggdrasil /128 addresses allowed through the firewall, unless they
# were given on the command line or the run is explicitly non-interactive.
# These are the only addresses that will be able to reach the router or the LAN
# over Yggdrasil, so getting them wrong is what locks remote access out.
prompt_trusted() {
    [ -n "$TRUSTED" ] && return 0
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ -t 0 ] || return 0

    # If this session already arrived over Yggdrasil, offer that address.
    _sugg=''
    case "${SSH_CLIENT:-}" in
        2??:*|3??:*) _sugg="${SSH_CLIENT%% *}" ;;
    esac

    printf '\n%s%s\n' "$C_HDR" "$RULE" >&2
    printf ' Trusted Yggdrasil clients\n' >&2
    printf '%s%s\n' "$RULE" "$C_RST" >&2
    printf '  Only these Yggdrasil addresses will be allowed to reach this\n' >&2
    printf '  router and the LAN. Enter one per line; empty line when done.\n' >&2
    [ -n "$_sugg" ] && printf '  (press Enter on the first line to use %s)\n' "$_sugg" >&2
    printf '  Leaving the list empty creates a fully closed ygg zone.\n\n' >&2

    while : ; do
        printf '  trusted address> ' >&2
        read -r _in || break
        if [ -z "$_in" ]; then
            if [ -z "$TRUSTED" ] && [ -n "$_sugg" ]; then
                add_trusted "$_sugg"
                ok "using $_sugg"
                continue
            fi
            break
        fi
        case "$_in" in
            2??:*|3??:*)
                case "$_in" in
                    */*) warn "give a bare /128 address, without a prefix length"; continue ;;
                esac
                add_trusted "$_in"; ok "added $_in" ;;
            *) warn "not a Yggdrasil 200::/7 address, ignored: $_in" ;;
        esac
    done
}

# --------------------------------------------------------------- utilities ---

# uci wrapper that is quiet about "entry not found" on deletes
uci_del() {
    [ "$DRY_RUN" -eq 1 ] && { printf '    would run: uci -q delete %s\n' "$1" >&2; return 0; }
    uci -q delete "$1" 2>/dev/null || true
}

uci_set() {
    if [ "$DRY_RUN" -eq 1 ]; then
        # The private key is the node identity: never print it, not even here.
        case "$1" in
            *.private_key) printf '    would run: uci set %s=<REDACTED %s hex chars>\n' "$1" "${#2}" >&2 ;;
            *)             printf '    would run: uci set %s=%s\n' "$1" "$2" >&2 ;;
        esac
        return 0
    fi
    uci set "$1=$2"
}

uci_add_list() {
    [ "$DRY_RUN" -eq 1 ] && { printf '    would run: uci add_list %s=%s\n' "$1" "$2" >&2; return 0; }
    uci add_list "$1=$2"
}

confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ "$DRY_RUN" -eq 1 ] && return 0
    printf '%s [y/N] ' "$1" >&2
    read -r _a </dev/tty 2>/dev/null || return 1
    case "$_a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# The private key is the node identity: supplying the old one is the only way to
# keep an existing Yggdrasil address when redeploying or moving to new hardware.
# It is deliberately not accepted as a command-line value — /proc/<pid>/cmdline
# is world readable, so an argument would expose the key to every process on the
# router for the length of the run, and leave it in the shell history of whoever
# typed it and in the ssh command line if the script was piped in. A file or the
# environment keeps it out of argv.
load_supplied_key() {
    _k=''
    if [ -n "$PRIVATE_KEY_FILE" ]; then
        [ -r "$PRIVATE_KEY_FILE" ] || die "cannot read private key file: $PRIVATE_KEY_FILE"
        # BusyBox find has no -printf, so the mode string comes from ls.
        # shellcheck disable=SC2012
        _mode="$(ls -ld "$PRIVATE_KEY_FILE" 2>/dev/null | cut -c1-10)"
        case "$_mode" in
            ????------) : ;;
            *) warn "key file is readable beyond its owner ($_mode): $PRIVATE_KEY_FILE" ;;
        esac
        _k="$(tr -d ' \t\r\n' < "$PRIVATE_KEY_FILE")"
        _src="$PRIVATE_KEY_FILE"
    elif [ -n "${YGG_PRIVATE_KEY:-}" ]; then
        _k="$(printf '%s' "$YGG_PRIVATE_KEY" | tr -d ' \t\r\n')"
        _src='the YGG_PRIVATE_KEY environment variable'
    else
        return 0
    fi

    # Never echo the value itself, not even in an error.
    case "${#_k}" in
        128) : ;;
        *) die "private key from $_src is ${#_k} characters, expected 128 hex" ;;
    esac
    case "$_k" in
        *[!0-9a-fA-F]*) die "private key from $_src contains non-hex characters" ;;
    esac

    SUPPLIED_KEY="$_k"
    ok "private key loaded from $_src (128 hex chars)"
}

# ---------------------------------------------------------------- rollback ---

rollback() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    [ -n "$BACKUP_DIR" ] || return 0
    [ -d "$BACKUP_DIR" ] || return 0
    [ "$CHANGED_NETWORK$CHANGED_DHCP$CHANGED_FIREWALL" = "000" ] && return 0

    warn "rolling back UCI configuration from $BACKUP_DIR"
    for _c in network dhcp firewall; do
        _flag=0
        case "$_c" in
            network)  _flag=$CHANGED_NETWORK ;;
            dhcp)     _flag=$CHANGED_DHCP ;;
            firewall) _flag=$CHANGED_FIREWALL ;;
        esac
        [ "$_flag" -eq 1 ] || continue
        if [ -f "$BACKUP_DIR/$_c" ]; then
            uci -q revert "$_c" 2>/dev/null || true
            cp "$BACKUP_DIR/$_c" "/etc/config/$_c" && warn "  restored /etc/config/$_c"
        fi
    done
    /etc/init.d/network reload  >/dev/null 2>&1 || true
    /etc/init.d/odhcpd restart  >/dev/null 2>&1 || true
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    warn "rollback done — verify the router state manually"
}

# =========================================================== stage 0: preflight

stage_preflight() {
    FAILED_STAGE='preflight'
    step "Stage 0 — preflight"

    [ "$(id -u 2>/dev/null || echo 0)" = "0" ] || die "must run as root"
    [ -f /etc/openwrt_release ] || die "/etc/openwrt_release missing — this is not OpenWrt"

    # shellcheck disable=SC1091
    . /etc/openwrt_release
    info "device : $(cat /tmp/sysinfo/model 2>/dev/null || echo unknown)"
    info "release: ${DISTRIB_DESCRIPTION:-unknown} (${DISTRIB_TARGET:-?}, $(uname -m))"

    for _t in uci ubus jsonfilter ifstatus; do
        have "$_t" || die "required tool missing: $_t"
    done

    if have apk; then
        PKG='apk'; PKG_UPDATE='apk update'; PKG_ADD='apk add'
    elif have opkg; then
        PKG='opkg'; PKG_UPDATE='opkg update'; PKG_ADD='opkg install'
        warn "this router uses opkg; the design is documented against OpenWrt 25.12+ with apk"
        warn "package names and the yggdrasil netifd proto may differ — proceeding, but verify"
    else
        die "neither apk nor opkg found"
    fi
    info "package manager: $PKG"

    uci -q get "network.$LAN" >/dev/null 2>&1 || die "no UCI interface 'network.$LAN' — pass --lan"

    # free space check: the status module + packages need a little room
    _free=$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}')
    [ -z "$_free" ] && _free=$(df -k / 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$_free" ] && [ "$_free" -lt 2048 ]; then
        warn "only ${_free}KB free on the overlay — package installation may fail"
    fi

    load_supplied_key

    # detect an existing deployment
    EXISTING_KEY="$(uci -q get "network.$IFACE.private_key" 2>/dev/null || true)"
    if [ -n "$SUPPLIED_KEY" ]; then
        ok "a private key was supplied — the restored identity WILL BE USED"
        info "    (this router takes the node address that key belongs to)"
    elif [ -n "$EXISTING_KEY" ]; then
        ok "existing Yggdrasil interface '$IFACE' found — its private key WILL BE PRESERVED"
        info "    (node address and routed /64 stay the same)"
    else
        info "no existing '$IFACE' — a new key pair will be generated"
    fi

    info "peers to configure ($PEERS_MODE):"
    printf '%s\n' "$PEERS" | while IFS= read -r _p; do [ -n "$_p" ] && info "    $_p"; done
    if [ -n "$TRUSTED" ]; then
        info "trusted Yggdrasil /128:"
        printf '%s\n' "$TRUSTED" | while IFS= read -r _t; do [ -n "$_t" ] && info "    $_t"; done
    elif [ "$DO_FIREWALL" -eq 1 ]; then
        warn "no --trusted given: the ygg zone will be created closed (no remote access)"
    fi

    if [ "$DRY_RUN" -eq 0 ]; then
        BACKUP_DIR="/root/ygg-deploy-backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BACKUP_DIR" || die "cannot create $BACKUP_DIR"
        for _c in network dhcp firewall; do
            [ -f "/etc/config/$_c" ] && cp "/etc/config/$_c" "$BACKUP_DIR/$_c"
        done
        uci export network  > "$BACKUP_DIR/network.uciexport"  2>/dev/null || true
        uci export dhcp     > "$BACKUP_DIR/dhcp.uciexport"     2>/dev/null || true
        uci export firewall > "$BACKUP_DIR/firewall.uciexport" 2>/dev/null || true
        ok "backup written to $BACKUP_DIR"
    fi

    # refuse to run on top of uncommitted changes we would otherwise commit blindly
    if [ "$DRY_RUN" -eq 0 ]; then
        for _c in network dhcp firewall; do
            if [ -n "$(uci -q changes "$_c" 2>/dev/null)" ]; then
                err "uncommitted UCI changes exist in '$_c':"
                uci -q changes "$_c" >&2
                die "commit or revert them first — refusing to mix them into this deployment"
            fi
        done
    fi

    confirm "Apply this deployment to $(cat /tmp/sysinfo/model 2>/dev/null || echo 'this router')?" \
        || die "aborted by operator"
}

# =========================================================== stage 1: packages

stage_packages() {
    FAILED_STAGE='packages'
    step "Stage 1 — packages"

    _want='yggdrasil luci-proto-yggdrasil'
    [ "$DO_JUMPER" -eq 1 ] && _want="$_want yggdrasil-jumper"
    [ "$DO_STATUS" -eq 1 ] && _want="$_want iputils-arping"

    _missing=''
    for _p in $_want; do
        if [ "$PKG" = 'apk' ]; then
            apk info -e "$_p" >/dev/null 2>&1 && continue
        else
            opkg list-installed 2>/dev/null | grep -q "^$_p " && continue
        fi
        _missing="$_missing $_p"
    done

    if [ -z "$_missing" ]; then
        # shellcheck disable=SC2086
        ok "all packages already installed:$(printf ' %s' $_want)"
        return 0
    fi

    info "installing:$_missing"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    would run: %s\n' "$PKG_UPDATE" >&2
        printf '    would run: %s%s\n' "$PKG_ADD" "$_missing" >&2
        return 0
    fi

    # shellcheck disable=SC2086
    $PKG_UPDATE >/dev/null 2>&1 || warn "package index update failed — trying to install anyway"

    for _p in $_missing; do
        # shellcheck disable=SC2086
        if $PKG_ADD "$_p" >/dev/null 2>&1; then
            ok "installed $_p"
        else
            case "$_p" in
                yggdrasil-jumper)
                    warn "yggdrasil-jumper not available — continuing without it (optional)"
                    DO_JUMPER=0 ;;
                iputils-arping)
                    warn "iputils-arping not available — status module presence checks will degrade" ;;
                *)
                    die "failed to install required package: $_p" ;;
            esac
        fi
    done

    [ -f /lib/netifd/proto/yggdrasil.sh ] \
        || die "netifd yggdrasil proto handler missing after install (/lib/netifd/proto/yggdrasil.sh)"
    ok "netifd yggdrasil proto handler present"
}

# ================================================ stage 2: yggdrasil interface

gen_private_key() {
    # yggdrasil 0.5.x: -genconf -json emits PrivateKey as 128 hex chars
    # (ed25519 seed || public key). No PublicKey field is emitted.
    _json="$(yggdrasil -genconf -json 2>/dev/null)" || return 1
    printf '%s' "$_json" | jsonfilter -e '@.PrivateKey' 2>/dev/null
}

pub_from_priv() {
    # The last 64 hex chars of an ed25519 private key ARE the public key.
    printf '%s' "$1" | cut -c65-128
}

stage_yggdrasil() {
    FAILED_STAGE='yggdrasil interface'
    step "Stage 2 — Yggdrasil interface '$IFACE'"

    CHANGED_NETWORK=1

    _priv="$EXISTING_KEY"
    if [ -n "$SUPPLIED_KEY" ]; then
        if [ -n "$EXISTING_KEY" ] && [ "$EXISTING_KEY" != "$SUPPLIED_KEY" ]; then
            warn "this router already has a different Yggdrasil identity"
            warn "applying the supplied key CHANGES its node address and routed /64"
            confirm "  replace the existing identity?" \
                || die "aborted — omit --private-key-file to keep the existing key, or pass -y"
        fi
        _priv="$SUPPLIED_KEY"
        ok "using the supplied private key"
    fi
    if [ -z "$_priv" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            info "would generate a new key pair via: yggdrasil -genconf -json"
            _priv='00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000'
        else
            have yggdrasil || die "yggdrasil binary not found after package install"
            _priv="$(gen_private_key)" || die "yggdrasil -genconf -json failed"
            [ -n "$_priv" ] || die "could not extract PrivateKey from yggdrasil -genconf -json"
            case "${#_priv}" in
                128) : ;;
                *)   die "unexpected private key length (${#_priv}, expected 128 hex chars)" ;;
            esac
            ok "generated a new key pair"
        fi
    fi
    _pub="$(pub_from_priv "$_priv")"

    uci_set "network.$IFACE" 'interface'
    uci_set "network.$IFACE.proto" 'yggdrasil'
    uci_set "network.$IFACE.private_key" "$_priv"
    uci_set "network.$IFACE.public_key" "$_pub"
    # ip6class on the provider side is a no-op for this proto; drop any stray one
    uci_del "network.$IFACE.ip6class"

    if [ "$DO_JUMPER" -eq 1 ]; then
        uci_set "network.$IFACE.jumper_enable" '1'
        uci_set "network.$IFACE.jumper_loglevel" 'info'
        uci_set "network.$IFACE.allocate_listen_addresses" '1'
        uci_set "network.$IFACE.jumper_autofill_listen_addresses" '1'
        uci_set "network.$IFACE.multipath" 'off'
        info "jumper profile enabled"
    else
        uci_set "network.$IFACE.jumper_enable" '0'
        info "jumper disabled"
    fi

    # --- peers ---------------------------------------------------------------
    _peer_type="yggdrasil_${IFACE}_peer"
    if [ "$PEERS_MODE" = 'replace' ]; then
        _n=0
        if [ "$DRY_RUN" -eq 0 ]; then
            # delete from the end so indices stay valid
            _count="$(uci show network 2>/dev/null | grep -c "=$_peer_type\$" || true)"
            [ -z "$_count" ] && _count=0
            while [ "$_count" -gt 0 ]; do
                _count=$((_count - 1))
                uci -q delete "network.@${_peer_type}[${_count}]" 2>/dev/null || true
                _n=$((_n + 1))
            done
        fi
        [ "$_n" -gt 0 ] && info "removed $_n existing peer section(s)"
    fi

    _existing_peers=''
    if [ "$PEERS_MODE" = 'add' ] && [ "$DRY_RUN" -eq 0 ]; then
        _existing_peers="$(uci show network 2>/dev/null \
            | sed -n "s/^network\.@$_peer_type\[[0-9]*\]\.address='\(.*\)'\$/\1/p")"
    fi

    _added=0
    printf '%s\n' "$PEERS" | while IFS= read -r _p; do
        [ -n "$_p" ] || continue
        if printf '%s\n' "$_existing_peers" | grep -qxF "$_p"; then
            info "peer already present, skipping: $_p"
            continue
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
            printf '    would add peer: %s\n' "$_p" >&2
        else
            _s="$(uci add network "$_peer_type")" || exit 1
            uci set "network.$_s.address=$_p" || exit 1
            printf '[+] peer added: %s\n' "$_p" >&2
        fi
    done || die "failed while adding peer sections"

    # --- LAN multicast peering ----------------------------------------------
    _mc_type="yggdrasil_${IFACE}_interface"
    _lan_dev="$(uci -q get "network.$LAN.device" 2>/dev/null)"
    [ -n "$_lan_dev" ] || _lan_dev='br-lan'
    if [ "$DO_MULTICAST" -eq 1 ]; then
        if [ "$DRY_RUN" -eq 0 ]; then
            _count="$(uci show network 2>/dev/null | grep -c "=$_mc_type\$" || true)"
            [ -z "$_count" ] && _count=0
            while [ "$_count" -gt 0 ]; do
                _count=$((_count - 1))
                uci -q delete "network.@${_mc_type}[${_count}]" 2>/dev/null || true
            done
            _s="$(uci add network "$_mc_type")"
            uci add_list "network.$_s.interface=$_lan_dev"
            uci set "network.$_s.beacon=1"
            uci set "network.$_s.listen=1"
        fi
        info "LAN multicast peering on '$_lan_dev' (beacon=1 listen=1)"
    fi

    if [ "$DRY_RUN" -eq 0 ]; then
        uci commit network || die "uci commit network failed"
        ok "network committed"
        info "reloading network…"
        /etc/init.d/network reload >/dev/null 2>&1 || die "network reload failed"
        sleep 3

        # netifd sources /lib/netifd/proto/*.sh only at startup. A protocol
        # handler installed during this run is invisible to the already-running
        # netifd, and the interface then comes up as proto 'none' + NO_DEVICE.
        # A reload does not fix that; only restarting netifd does.
        _proto="$(ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@.proto' 2>/dev/null)"
        if [ "$_proto" != 'yggdrasil' ]; then
            warn "netifd reports proto='${_proto:-unset}' for '$IFACE'"
            warn "restarting netifd so it loads the freshly installed yggdrasil proto handler"
            warn "  (this briefly bounces every interface, LAN included)"
            /etc/init.d/network restart >/dev/null 2>&1 || die "network restart failed"
            _i=0
            while [ "$_i" -lt 30 ]; do
                _proto="$(ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@.proto' 2>/dev/null)"
                [ "$_proto" = 'yggdrasil' ] && break
                _i=$((_i + 2)); sleep 2
            done
            [ "$_proto" = 'yggdrasil' ] \
                || die "netifd still does not know proto 'yggdrasil' (got '${_proto:-unset}')"
            ok "netifd restarted, yggdrasil proto handler loaded"
        fi
    fi
}

# =============================================== stage 3: wait for the prefix

get_node_addr() {
    ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@["ipv6-address"][0].address' 2>/dev/null
}

# Emits "<address>/<mask> <class>" for the prefix delegated by the Ygg interface.
#
# netifd labels a delegated prefix with the class of the interface that provided
# it, and that class defaults to the UCI interface name — so on a section called
# 'ygg0' the class is "ygg0", not "ygg". Setting ip6class on the Ygg interface
# does NOT override it (verified on OpenWrt 25.12.5 / luci-proto-yggdrasil
# 1.1.1). The class is therefore read back at runtime instead of assumed, so a
# future handler that publishes a different class still works.
get_ygg_prefix() {
    ifstatus "$IFACE" 2>/dev/null \
        | jsonfilter -e '@["ipv6-prefix"][*]' 2>/dev/null \
        | while IFS= read -r _o; do
            _adr="$(printf '%s' "$_o" | jsonfilter -e '@.address' 2>/dev/null)"
            [ -n "$_adr" ] || continue
            _msk="$(printf '%s' "$_o" | jsonfilter -e '@.mask' 2>/dev/null)"
            _cls="$(printf '%s' "$_o" | jsonfilter -e '@.class' 2>/dev/null)"
            printf '%s/%s %s\n' "$_adr" "${_msk:-64}" "${_cls:-$IFACE}"
            break
        done
}

stage_wait() {
    FAILED_STAGE='waiting for the Yggdrasil prefix'
    step "Stage 3 — wait for node address and routed /64"

    if [ "$DRY_RUN" -eq 1 ]; then
        info "would poll 'ifstatus $IFACE' for up to ${WAIT_SECS}s"
        NODE_ADDR='200:dry:run'
        YGG_PREFIX='300:dry:run::/64'
        YGG_CLASS="$IFACE"
        return 0
    fi

    NODE_ADDR=''
    YGG_PREFIX=''
    YGG_CLASS=''
    _i=0
    while [ "$_i" -lt "$WAIT_SECS" ]; do
        NODE_ADDR="$(get_node_addr)"
        _pfx_line="$(get_ygg_prefix)"
        YGG_PREFIX="${_pfx_line%% *}"
        YGG_CLASS="${_pfx_line##* }"
        [ -n "$NODE_ADDR" ] && [ -n "$YGG_PREFIX" ] && break
        _i=$((_i + 3))
        sleep 3
        [ $((_i % 15)) -eq 0 ] && info "  still waiting… ${_i}s"
    done

    [ -n "$NODE_ADDR" ]  || die "no node address on '$IFACE' after ${WAIT_SECS}s — check 'logread | grep -i ygg'"
    [ -n "$YGG_PREFIX" ] || die "no delegated /64 on '$IFACE' after ${WAIT_SECS}s — check 'ifstatus $IFACE'"

    ok "node address : $NODE_ADDR"
    ok "routed prefix: $YGG_PREFIX (netifd prefix class: $YGG_CLASS)"

    # The proto handler gives each interface its own admin socket under
    # /tmp/yggdrasil; a bare `yggdrasilctl` looks somewhere else and finds nothing.
    YGG_SOCK="unix:///tmp/yggdrasil/${IFACE}.sock"
    _up=0
    if have yggdrasilctl && [ -S "/tmp/yggdrasil/${IFACE}.sock" ]; then
        _up="$(yggdrasilctl -endpoint="$YGG_SOCK" getPeers 2>/dev/null \
               | awk 'NR>1 && $2=="Up"' | wc -l | tr -d ' ')"
        [ -z "$_up" ] && _up=0
    fi
    if [ "$_up" -gt 0 ]; then
        ok "$_up peer link(s) established"
    else
        warn "no established peer links reported by yggdrasilctl"
        warn "  check: yggdrasilctl -endpoint=$YGG_SOCK getPeers"
    fi
}

# ================================================= stage 4: LAN routed /64 + RA

stage_lan() {
    [ "$DO_LAN" -eq 1 ] || { info "skipping LAN stage (--no-lan)"; return 0; }
    FAILED_STAGE='LAN routed /64 and RA'
    step "Stage 4 — LAN routed /64 and SLAAC-only RA"

    CHANGED_NETWORK=1
    CHANGED_DHCP=1

    # ip6class must name the class netifd actually publishes for this prefix
    # (see get_ygg_prefix); hardcoding 'ygg' silently matches nothing and the
    # LAN then keeps whatever other prefix it can find.
    _class="${YGG_CLASS:-$IFACE}"
    uci_set "network.$LAN.ip6assign" '64'
    uci_del "network.$LAN.ip6class"
    uci_add_list "network.$LAN.ip6class" "$_class"
    uci_del 'network.globals.ula_prefix'
    info "LAN: ip6assign=64, ip6class=$_class, extra ULA removed"

    uci -q get "dhcp.$LAN" >/dev/null 2>&1 || die "no UCI section 'dhcp.$LAN'"
    uci_set "dhcp.$LAN.dhcpv6" 'disabled'
    uci_set "dhcp.$LAN.ra" 'server'
    uci_set "dhcp.$LAN.ra_slaac" '1'
    uci_del "dhcp.$LAN.ra_flags"
    uci_add_list "dhcp.$LAN.ra_flags" 'none'
    uci_set "dhcp.$LAN.ra_default" '2'
    uci_set "dhcp.$LAN.ra_preference" 'medium'
    info "DHCPv6 disabled, RA=server, SLAAC-only"

    if [ "$DRY_RUN" -eq 0 ]; then
        uci commit network || die "uci commit network failed"
        uci commit dhcp    || die "uci commit dhcp failed"
        /etc/init.d/network reload >/dev/null 2>&1 || die "network reload failed"
        /etc/init.d/odhcpd restart >/dev/null 2>&1 || die "odhcpd restart failed"
        ok "LAN configuration applied"
    fi
}

# ===================================================== stage 5: firewall policy

fw_rule_trusted() {
    # $1 = section name, $2 = human name, and the caller pre-sets the specifics
    _sec="$1"
    uci_del "firewall.$_sec.src_ip"
    printf '%s\n' "$TRUSTED" | while IFS= read -r _t; do
        [ -n "$_t" ] || continue
        if [ "$DRY_RUN" -eq 1 ]; then
            printf '    would run: uci add_list firewall.%s.src_ip=%s\n' "$_sec" "$_t" >&2
        else
            uci add_list "firewall.$_sec.src_ip=$_t"
        fi
    done
}

stage_firewall() {
    [ "$DO_FIREWALL" -eq 1 ] || { info "skipping firewall stage (--no-firewall)"; return 0; }
    FAILED_STAGE='firewall'
    step "Stage 5 — firewall zone and trusted rules"

    CHANGED_FIREWALL=1

    uci_set 'firewall.ygg' 'zone'
    uci_set 'firewall.ygg.name' 'ygg'
    uci_set 'firewall.ygg.input' 'REJECT'
    uci_set 'firewall.ygg.output' 'ACCEPT'
    uci_set 'firewall.ygg.forward' 'DROP'
    uci_del 'firewall.ygg.network'
    uci_add_list 'firewall.ygg.network' "$IFACE"
    uci_del 'firewall.ygg.masq'
    uci_del 'firewall.ygg.masq6'
    ok "zone 'ygg': input REJECT / output ACCEPT / forward DROP, no NAT66"

    if [ -z "$TRUSTED" ]; then
        warn "no trusted /128 given — removing any previously created allow rules"
        uci_del 'firewall.ygg_trusted_lan'
        uci_del 'firewall.ygg_trusted_router'
    else
        uci_set 'firewall.ygg_trusted_lan' 'rule'
        uci_set 'firewall.ygg_trusted_lan.name' 'YGG-Trusted-to-LAN'
        uci_set 'firewall.ygg_trusted_lan.src' 'ygg'
        uci_set 'firewall.ygg_trusted_lan.dest' "$LAN"
        uci_set 'firewall.ygg_trusted_lan.family' 'ipv6'
        uci_set 'firewall.ygg_trusted_lan.proto' 'all'
        uci_set 'firewall.ygg_trusted_lan.target' 'ACCEPT'
        fw_rule_trusted 'ygg_trusted_lan'

        uci_set 'firewall.ygg_trusted_router' 'rule'
        uci_set 'firewall.ygg_trusted_router.name' 'YGG-Trusted-to-Router'
        uci_set 'firewall.ygg_trusted_router.src' 'ygg'
        uci_set 'firewall.ygg_trusted_router.family' 'ipv6'
        uci_set 'firewall.ygg_trusted_router.proto' 'tcp'
        uci_set 'firewall.ygg_trusted_router.target' 'ACCEPT'
        fw_rule_trusted 'ygg_trusted_router'
        ok "trusted allow rules written (LAN + router)"
    fi

    if [ "$DRY_RUN" -eq 0 ]; then
        uci commit firewall || die "uci commit firewall failed"
        /etc/init.d/firewall reload >/dev/null 2>&1 || die "firewall reload failed"
        ok "firewall reloaded"
    fi
}

# ================================================ stage 6: DNS over Yggdrasil

# Part III of the design (AI_CONTEXT.md section 10, REFERENCE_CONFIG.md 6-7).
# One 'config domain' record serves two roles at once: persistent canonical Ygg
# metadata for the status page, and a plain dnsmasq answer. No extra daemon.

dns_section() {
    # $1 = record name, $2 = address. Both go into the UCI section id, so a host
    # with two addresses on the routed /64 gets two records instead of
    # overwriting itself, and re-running the script stays idempotent.
    printf 'ygg_dns_%s' "$(printf '%s_%s' "$1" "$2" | tr -c 'A-Za-z0-9' '_')"
}

dns_purge() {
    # $1 = fully qualified record name. Drop every record this script owns for
    # that name, so a changed address cannot leave a stale second answer.
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    would run: drop existing ygg_dns_* records for %s\n' "$1" >&2
        return 0
    fi
    uci show dhcp 2>/dev/null \
        | grep -F ".name='$1'" \
        | grep '^dhcp\.ygg_dns_' \
        | cut -d. -f2 \
        | while IFS= read -r _s; do
              [ -n "$_s" ] && uci -q delete "dhcp.$_s"
          done
    return 0
}

dns_record() {
    # $1 = fully qualified name, $2 = address
    _sec="$(dns_section "$1" "$2")"
    uci_set "dhcp.$_sec" 'domain'
    uci_set "dhcp.$_sec.name" "$1"
    uci_set "dhcp.$_sec.ip" "$2"
    info "record $1 -> $2"
}

stage_dns() {
    [ "$DO_DNS" -eq 1 ] || { info "skipping DNS module (--no-dns)"; return 0; }
    FAILED_STAGE='DNS over Yggdrasil'
    step "Stage 6 — DNS over Yggdrasil"

    uci -q get 'dhcp.@dnsmasq[0]' >/dev/null 2>&1 \
        || die "no dnsmasq section in /etc/config/dhcp"

    CHANGED_DHCP=1

    # "<fqdn> <address>" per line: the router first, then every --dns-host.
    _records="${DNS_ROUTER}.${DNS_DOMAIN} ${NODE_ADDR}"
    _oifs="$IFS"
    IFS='
'
    for _h in $DNS_HOSTS; do
        [ -n "$_h" ] || continue
        _records="${_records}
${_h%%=*}.${DNS_DOMAIN} ${_h#*=}"
    done
    for _r in $_records; do
        dns_purge "${_r%% *}"
    done
    for _r in $_records; do
        dns_record "${_r%% *}" "${_r##* }"
    done
    IFS="$_oifs"

    # Answer this namespace locally instead of forwarding it to the WAN resolver.
    # NB: the documented equivalent, 'local=/domain/', must NOT be turned into a
    # UCI list — /etc/init.d/dnsmasq emits a single 'local=' line and joins list
    # values with spaces, which is invalid and stops dnsmasq from starting.
    # 'server' is emitted as one line per value, and 'server=/domain/' with no
    # target is dnsmasq's exact equivalent of 'local=/domain/'.
    if uci -q get 'dhcp.@dnsmasq[0].server' 2>/dev/null \
        | tr ' ' '\n' | grep -qxF "/$DNS_DOMAIN/"
    then
        info "dnsmasq already authoritative for $DNS_DOMAIN"
    else
        uci_add_list 'dhcp.@dnsmasq[0].server' "/$DNS_DOMAIN/"
        info "dnsmasq made authoritative for $DNS_DOMAIN"
    fi

    if [ "$DO_FIREWALL" -eq 0 ]; then
        warn "--no-firewall: port 53 not opened, DNS stays LAN-only"
    elif [ -z "$TRUSTED" ]; then
        CHANGED_FIREWALL=1
        uci_del 'firewall.ygg_dns'
        warn "no trusted /128: DNS will not be reachable over Yggdrasil"
    else
        CHANGED_FIREWALL=1
        uci_set 'firewall.ygg_dns' 'rule'
        uci_set 'firewall.ygg_dns.name' 'Allow-DNS-from-Trusted-Yggdrasil'
        uci_set 'firewall.ygg_dns.src' 'ygg'
        uci_set 'firewall.ygg_dns.family' 'ipv6'
        uci_set 'firewall.ygg_dns.proto' 'tcp udp'
        uci_set 'firewall.ygg_dns.dest_port' '53'
        uci_set 'firewall.ygg_dns.target' 'ACCEPT'
        fw_rule_trusted 'ygg_dns'
        ok "port 53 opened for the trusted addresses only"
    fi

    if [ "$DRY_RUN" -eq 0 ]; then
        uci commit dhcp || die "uci commit dhcp failed"
        /etc/init.d/dnsmasq restart >/dev/null 2>&1 || die "dnsmasq restart failed"

        # A dnsmasq that cannot parse its config exits without a word, taking
        # LAN name resolution with it. Do not leave this stage until it is back.
        _n=0
        while [ "$_n" -lt 10 ]; do
            pidof dnsmasq >/dev/null 2>&1 && break
            _n=$((_n + 1))
            sleep 1
        done
        pidof dnsmasq >/dev/null 2>&1 || die "dnsmasq is not running after restart"

        if [ "$DO_FIREWALL" -eq 1 ]; then
            uci commit firewall || die "uci commit firewall failed"
            /etc/init.d/firewall reload >/dev/null 2>&1 || die "firewall reload failed"
        fi
        ok "DNS module applied"
    fi
}

# ================================================== stage 7: LuCI status module

stage_status() {
    [ "$DO_STATUS" -eq 1 ] || { info "skipping status module (--no-status)"; return 0; }
    FAILED_STAGE='LuCI status module'
    step "Stage 7 — LuCI status module"

    if [ "$DRY_RUN" -eq 1 ]; then
        info "would install the status module from ${STATUS_PKG:-${STATUS_URL:-$STATUS_BASE}}"
        return 0
    fi

    _tmp='/tmp/ygg-status-deploy'
    rm -rf "$_tmp"; mkdir -p "$_tmp" || { warn "cannot create $_tmp"; return 0; }
    _tgz="$_tmp/yggdrasil-status-v5.tar.gz"

    _fetch() { # $1 = url, $2 = destination
        wget -q -O "$2" "$1" 2>/dev/null \
            || uclient-fetch -q -O "$2" "$1" 2>/dev/null \
            || curl -fsSL -o "$2" "$1" 2>/dev/null
    }

    _verify() { # $1 = tarball, $2 = expected sha256 (may be empty)
        [ -n "$2" ] || { warn "could not verify the package checksum"; return 0; }
        have sha256sum || { warn "sha256sum missing — cannot verify the package"; return 0; }
        _got="$(sha256sum "$1" | awk '{print $1}')"
        [ "$2" = "$_got" ] && { ok "checksum verified"; return 0; }
        warn "status module checksum mismatch — refusing to install"
        warn "  expected $2"
        warn "  got      $_got"
        return 1
    }

    if [ -n "$STATUS_PKG" ]; then
        [ -r "$STATUS_PKG" ] || { warn "cannot read $STATUS_PKG — skipping status module"; return 0; }
        cp "$STATUS_PKG" "$_tgz"
        info "using local package $STATUS_PKG"
        [ -r "$STATUS_PKG.sha256" ] \
            && { _verify "$_tgz" "$(awk '{print $1}' "$STATUS_PKG.sha256")" || return 0; }
    elif [ -n "$STATUS_URL" ]; then
        info "downloading $STATUS_URL"
        _fetch "$STATUS_URL" "$_tgz" || { warn "download failed — skipping status module"; return 0; }
        _fetch "$STATUS_URL.sha256" "$_tgz.sha256"
        _verify "$_tgz" "$(awk '{print $1}' "$_tgz.sha256" 2>/dev/null)" || return 0
    else
        # A checkout of this repository ships the package next to the script;
        # prefer it, so a run from a checkout installs the version being tested.
        _local_dir="$(dirname "$0")/../packages"
        _got_pkg=0
        for _v in $STATUS_VERSIONS; do
            if [ -r "$_local_dir/$_v.tar.gz" ]; then
                cp "$_local_dir/$_v.tar.gz" "$_tgz"
                info "using $_v from the local checkout"
                [ -r "$_local_dir/$_v.tar.gz.sha256" ] \
                    && { _verify "$_tgz" "$(awk '{print $1}' "$_local_dir/$_v.tar.gz.sha256")" || return 0; }
                _got_pkg=1; break
            fi
        done
        if [ "$_got_pkg" -eq 0 ]; then
            for _v in $STATUS_VERSIONS; do
                info "downloading $STATUS_BASE/$_v.tar.gz"
                if _fetch "$STATUS_BASE/$_v.tar.gz" "$_tgz"; then
                    _fetch "$STATUS_BASE/$_v.tar.gz.sha256" "$_tgz.sha256"
                    _verify "$_tgz" "$(awk '{print $1}' "$_tgz.sha256" 2>/dev/null)" || return 0
                    case "$_v" in
                        yggdrasil-status-v5)
                            warn "fell back to v5: it resolves the routed /64 only when the"
                            warn "  Yggdrasil interface is named 'ygg'; with '$IFACE' the LAN"
                            warn "  clients table will show no IPv6 addresses" ;;
                    esac
                    _got_pkg=1; break
                fi
            done
        fi
        if [ "$_got_pkg" -eq 0 ]; then
            warn "no status module package available — skipping (core routing is unaffected)"
            warn "  install it later with: $SELF --no-lan --no-firewall --status-pkg /path/to.tar.gz"
            return 0
        fi
    fi

    ( cd "$_tmp" && tar -xzf "$_tgz" ) || { warn "tar extraction failed — skipping"; return 0; }
    _inst="$(find "$_tmp" -name install.sh -type f 2>/dev/null | head -n1)"
    [ -n "$_inst" ] || { warn "install.sh not found in the package — skipping"; return 0; }

    chmod +x "$_inst"
    info "running $_inst (it has its own backup + rollback)"
    if sh "$_inst"; then
        ok "status module installed"
    else
        warn "status module install failed and rolled itself back — core routing is unaffected"
        return 0
    fi

    if ubus -v list luci.yggdrasil-status >/dev/null 2>&1; then
        ok "RPC object luci.yggdrasil-status is registered"
    else
        warn "RPC object luci.yggdrasil-status not visible — check 'logread | grep rpcd'"
    fi
}

# ==================================================== stage 8: verification

check() {
    # $1 = label, $2 = expected, $3 = actual
    if [ "$2" = "$3" ]; then
        printf '  [OK]   %-28s %s\n' "$1" "$3" >&2
    else
        printf '  [FAIL] %-28s %s (expected: %s)\n' "$1" "${3:-<empty>}" "$2" >&2
        RC_OK=1
    fi
}

stage_verify() {
    FAILED_STAGE=''
    step "Stage 8 — verification"
    [ "$DRY_RUN" -eq 1 ] && { info "dry run — nothing to verify"; return 0; }

    printf '\nInvariants:\n' >&2
    check "$IFACE up"          'true'     "$(ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null)"
    check 'node address'       "$NODE_ADDR" "$(get_node_addr)"

    if [ "$DO_LAN" -eq 1 ]; then
        check 'LAN ip6assign'  '64'       "$(uci -q get "network.$LAN.ip6assign")"
        check 'LAN ip6class'   "${YGG_CLASS:-$IFACE}" "$(uci -q get "network.$LAN.ip6class")"
        check 'DHCPv6'         'disabled' "$(uci -q get "dhcp.$LAN.dhcpv6")"
        check 'RA'             'server'   "$(uci -q get "dhcp.$LAN.ra")"
        check 'RA SLAAC'       '1'        "$(uci -q get "dhcp.$LAN.ra_slaac")"
        check 'ula_prefix removed' ''     "$(uci -q get network.globals.ula_prefix)"
    fi

    if [ "$DO_FIREWALL" -eq 1 ]; then
        check 'ygg zone input'   'REJECT' "$(uci -q get firewall.ygg.input)"
        check 'ygg zone output'  'ACCEPT' "$(uci -q get firewall.ygg.output)"
        check 'ygg zone forward' 'DROP'   "$(uci -q get firewall.ygg.forward)"
        check 'no NAT66'         ''       "$(uci -q get firewall.ygg.masq6)"
    fi

    if [ "$DO_DNS" -eq 1 ]; then
        _dsec="$(dns_section "${DNS_ROUTER}.${DNS_DOMAIN}" "$NODE_ADDR")"
        check 'DNS router record' "$NODE_ADDR" "$(uci -q get "dhcp.$_dsec.ip")"
        check 'dnsmasq running'   'yes' \
            "$(pidof dnsmasq >/dev/null 2>&1 && echo yes || echo no)"
        if [ -n "$TRUSTED" ] && [ "$DO_FIREWALL" -eq 1 ]; then
            check 'DNS rule port'  '53' "$(uci -q get firewall.ygg_dns.dest_port)"
        fi
        # Resolve it for real. nslookup output varies between BusyBox builds, so
        # a mismatch is reported as a warning rather than a failed invariant.
        _dres="$(nslookup "${DNS_ROUTER}.${DNS_DOMAIN}" 127.0.0.1 2>/dev/null \
            | awk '/^Address:/ { a = $2 } END { print a }')"
        if [ "$_dres" = "$NODE_ADDR" ]; then
            ok "dnsmasq resolves ${DNS_ROUTER}.${DNS_DOMAIN} -> $NODE_ADDR"
        else
            warn "could not confirm ${DNS_ROUTER}.${DNS_DOMAIN} locally (got '${_dres:-nothing}')"
        fi
    fi

    if [ -S "/tmp/yggdrasil/${IFACE}.sock" ]; then
        printf '\nPeers:\n' >&2
        yggdrasilctl -endpoint="unix:///tmp/yggdrasil/${IFACE}.sock" getPeers 2>/dev/null \
            | awk 'NR==1 || $2=="Up" {printf "  %s %s %s\n", $1, $2, $3}' >&2
    fi

    printf '\nLAN state:\n' >&2
    _lan_dev="$(uci -q get "network.$LAN.device" 2>/dev/null)"; [ -n "$_lan_dev" ] || _lan_dev='br-lan'
    ip -6 addr show dev "$_lan_dev" 2>/dev/null | sed -n 's/^ *inet6 /  /p' >&2

    _pfx="${YGG_PREFIX%%/*}"
    _pfx="${_pfx%::}"
    if ip -6 addr show dev "$_lan_dev" 2>/dev/null | grep -q "${_pfx%%:*}:"; then
        ok "LAN carries an address from the delegated prefix"
    else
        warn "LAN does not yet carry an address from $YGG_PREFIX — give odhcpd a moment, then re-check"
    fi

    if [ "$RC_OK" -ne 0 ]; then
        printf '\n%s%s%s\n' "$C_ERR" "$RULE" "$C_RST" >&2
        printf '%s%s FAILED — some invariants did not hold%s\n' \
            "$C_ERR" "$C_BLD" "$C_RST" >&2
        printf '%s%s%s\n\n' "$C_ERR" "$RULE" "$C_RST" >&2
        err "review the [FAIL] lines above before relying on this router"
        err "configuration backup is at ${BACKUP_DIR:-<none>}"
        return 0
    fi

    printf '\n%s%s%s\n' "$C_OK" "$RULE" "$C_RST" >&2
    printf '%s%s SUCCESS — Yggdrasil is up and this router is reachable%s\n' \
        "$C_OK" "$C_BLD" "$C_RST" >&2
    printf '%s%s%s\n\n' "$C_OK" "$RULE" "$C_RST" >&2

    printf '  Router Yggdrasil address\n' >&2
    printf '      %s%s%s%s\n\n' "$C_OK" "$C_BLD" "$NODE_ADDR" "$C_RST" >&2

    printf '  Routed prefix advertised to the LAN\n' >&2
    printf '      %s\n\n' "$YGG_PREFIX" >&2

    if [ -n "$TRUSTED" ]; then
        printf '  Reachable over Yggdrasil from\n' >&2
        printf '%s\n' "$TRUSTED" | while IFS= read -r _t; do
            [ -n "$_t" ] && printf '      %s\n' "$_t" >&2
        done
        printf '\n  Connect from one of those nodes\n' >&2
        printf '      %sssh root@%s%s\n' "$C_BLD" "$NODE_ADDR" "$C_RST" >&2
        printf '      http://[%s]/            (LuCI)\n\n' "$NODE_ADDR" >&2
        printf '  %sVerify that now, from a trusted node, before you rely on it.%s\n' \
            "$C_WRN" "$C_RST" >&2
        printf '  The ygg zone rejects everything else, ICMP included: a failing\n' >&2
        printf '  ping is expected, a failing ssh is not.\n' >&2
    else
        printf '  %sNo trusted address was configured.%s\n' "$C_WRN" "$C_RST" >&2
        printf '  The ygg zone is closed, so the router is NOT reachable over\n' >&2
        printf '  Yggdrasil. Re-run with --trusted <address> to open it.\n' >&2
    fi

    if [ "$DO_DNS" -eq 1 ]; then
        printf '\n  Private DNS namespace\n' >&2
        printf '      %s%s.%s%s -> %s\n' \
            "$C_BLD" "$DNS_ROUTER" "$DNS_DOMAIN" "$C_RST" "$NODE_ADDR" >&2
        printf '\n  A trusted client reaches those names by pointing its\n' >&2
        printf '  resolver for %s at the address above. That is suffix\n' "$DNS_DOMAIN" >&2
        printf '  routing, not a second entry in resolv.conf: resolver order\n' >&2
        printf '  is failover, which is not the same thing.\n' >&2
        printf '  client/linux/yggdrasil-split-dns does it for systemd-resolved.\n' >&2
        printf '  Then: %shttp://%s.%s/%s\n' \
            "$C_BLD" "$DNS_ROUTER" "$DNS_DOMAIN" "$C_RST" >&2
    fi

    printf '\n  Configuration backup: %s\n' "${BACKUP_DIR:-none}" >&2
    printf '%s%s%s\n' "$C_OK" "$RULE" "$C_RST" >&2
}

# ------------------------------------------------------------------- main ---

banner "$SELF $VERSION — routed Yggdrasil /64 for OpenWrt"
prompt_trusted
[ "$DRY_RUN" -eq 1 ] && warn "DRY RUN — no changes will be made"

stage_preflight
stage_packages
stage_yggdrasil
stage_wait
stage_lan
stage_firewall
stage_dns
stage_status
stage_verify

exit "$RC_OK"
