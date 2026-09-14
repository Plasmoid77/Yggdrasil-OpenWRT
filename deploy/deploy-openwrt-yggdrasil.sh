#!/bin/sh
# deploy-openwrt-yggdrasil.sh — automated deployment of the routed Yggdrasil /64
# design documented in this repository (README.md / QUICKSTART.md / REFERENCE_CONFIG.md).
#
# Runs ON the OpenWrt router, under BusyBox ash. POSIX sh only.
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage:
#   deploy-openwrt-yggdrasil.sh [--peer tls://host:port ...] [options]
#   ssh root@router sh -s -- --peer tls://host:port < deploy-openwrt-yggdrasil.sh
#
# Every option has a tested default. Peers given on the command line replace the
# configured set; without any, the existing peer sections are kept as they are.

set -u
umask 077

VERSION='1.9.0'
SELF="${0##*/}"
# Piped straight from a URL — wget -qO- ... | sh -s -- ... — $0 is the shell, so
# the banner and the usage text would announce themselves as "sh".
case "$SELF" in
    sh|ash|dash|bash|-sh|-ash|'') SELF='deploy-openwrt-yggdrasil.sh' ;;
esac

# ---------------------------------------------------------------- defaults ---

IFACE='ygg0'
LAN='lan'
PEERS=''
TRUSTED=''
# How LAN clients get an address from the routed /64. 'slaac': RA with the A
# flag, clients form their own addresses, DHCPv6 off (the profile every 1.x
# deployment has). 'dhcpv6': RA with M/O and no A flag, odhcpd assigns every
# address from the prefix, reservations by --host. Opt-in for now.
LAN_MODE='slaac'
HOSTS=''
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
# Follow the newest published status release instead of a version baked into
# this script, so a new module does not require a new deployer. --status-version
# pins one explicitly. Bytes are always checked against the checksum published
# beside the archive: that catches truncation and corruption, but the checksum
# and the archive come from the same release, so it is not a defence against a
# compromised release. Use --status-pkg with your own verified build when that
# distinction matters.
STATUS_VERSION=''
STATUS_REPO='Plasmoid77/Yggdrasil-OpenWRT'
STATUS_API="https://api.github.com/repos/$STATUS_REPO/releases/latest"
STATUS_RELEASE_BASE="https://github.com/$STATUS_REPO/releases/download"
STATUS_BASE=''
PRIVATE_KEY_FILE=''
CONFIG_KEY=''
CONFIG_KEY_SRC=''
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
    # Argument errors die before rollback() is defined; there is nothing to
    # roll back at that point, and ash would otherwise print "rollback: not found".
    if command -v rollback >/dev/null 2>&1; then rollback; fi
    exit 1
}

usage() {
    cat >&2 <<USAGE
$SELF $VERSION — deploy routed Yggdrasil /64 on OpenWrt

Every setting can come from the command line, from one settings file on the
router, or both:
  --config FILE         Read settings from FILE (format below). Repeatable.
                        Options are applied in the order given: a later
                        single value wins, lists accumulate.

Peers (optional; without any, the existing peer sections are kept):
  --peer URI            Public peer to configure. Repeatable. Replaces the
                        configured set. Schemes: tls tcp quic ws wss socks sockstls
  --peers-file FILE     Read peers from FILE, one URI per line (# = comment).

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

LAN addressing (default: SLAAC, as in every 1.x deployment):
  --dhcpv6              Router-managed addresses: RA keeps the default route
                        and sets M/O, the A flag is off, odhcpd assigns every
                        LAN address from the routed /64. Clients without a
                        DHCPv6 client (Android) get no address from it.
  --slaac               Back to SLAAC-only (RA with A flag, DHCPv6 off).
                        --dhcpv6 and --slaac: the last one given wins.
  --host NAME=MAC=HOSTID
  --host NAME=duid:HEX[%IAID]=HOSTID
                        Reserve <prefix>::HOSTID for one client (needs
                        --dhcpv6). HOSTID: 1-16 hex digits, not 0 or 1.
                        Match by MAC works for DUID-LLT/DUID-LL clients only;
                        give the DUID (and the IAID in hex, when one DUID
                        serves several interfaces) for anything else.
                        Repeatable. With the DNS module on, NAME.$DNS_DOMAIN
                        resolves to the reserved address.

Scope:
  --iface NAME          Yggdrasil interface / UCI section name (default: $IFACE)
  --lan NAME            LAN UCI interface name (default: $LAN)
  --no-jumper           Do not install/enable yggdrasil-jumper
  --no-multicast        Do not enable LAN multicast peering
  --no-lan              Do not touch LAN ip6assign/ip6class/RA/DHCPv6
  --no-firewall         Do not create the ygg zone or trusted rules
  --no-status           Do not install the LuCI status module
  --no-dns              Do not serve <name>.$DNS_DOMAIN over Yggdrasil
  --status-pkg PATH     Install a local tarball; PATH.sha256 is required
  --status-version VER  Install this status release (e.g. v5.2) instead of the
                        newest published one

Behaviour:
  -n, --dry-run         Print what would change; touch nothing
  -y, --yes             Non-interactive; do not prompt before applying
  --wait SECONDS        Seconds to wait for the Ygg prefix (default: $WAIT_SECS)
  -h, --help            This text

Settings file: one value per line under a [section] header, # starts a
comment, blank lines are ignored. Unknown sections are an error. Sections:
  [peers]           peer URIs                  (as --peer)
  [trusted]         Yggdrasil /128 addresses   (as --trusted)
  [private-key]     the 128 hex character key  (as --private-key-file)
  [iface] [lan]     one name each              (as --iface, --lan)
  [dns-domain] [dns-router]                    (as --dns-domain, --dns-router)
  [dns-hosts]       NAME=ADDR lines            (as --dns-host)
  [hosts]           NAME=MAC=HOSTID lines      (as --host)
  [status-pkg] [status-version]                (as --status-pkg, --status-version)
  [flags]           one per line: no-jumper no-multicast no-lan no-firewall
                    no-status dns no-dns dhcpv6 slaac
                                               (as the switches of the same name)
Keep the file mode 600 when it holds the key. --dry-run, --yes and --wait
describe the run, not the node, and stay on the command line.
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

# Lower-case, leading zeros dropped: the form odhcpd compares reservations in
# (it parses hostid with strtoull(.., 16)), so 010 and 10 are the same suffix.
lower_str() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# The MAC a --host key stands for: the MAC itself, or the one at the end of a
# DUID-LLT (type 1, 14 bytes) / DUID-LL (type 3, 10 bytes); empty otherwise.
mac_in_key() {
    case "$1" in
        mac) printf '%s' "$2" ;;
        duid)
            _mik="${2%%%*}"
            case "${#_mik}:$_mik" in
                28:0001*|20:0003*) printf '%s' "${_mik#"${_mik%????????????}"}" | sed 's/\(..\)/\1:/g; s/:$//' ;;
            esac ;;
    esac
}

norm_hostid() {
    _nh="$(printf '%s' "$1" | tr 'A-F' 'a-f' | sed 's/^0*//')"
    printf '%s' "${_nh:-0}"
}

add_host() {
    # NAME=MAC=HOSTID or NAME=duid:HEX[%IAID]=HOSTID -> "NAME mac|duid KEY HOSTID"
    case "$1" in
        *=*=*) : ;;
        *) die "--host expects NAME=MAC=HOSTID or NAME=duid:HEX[%IAID]=HOSTID: $1" ;;
    esac
    _hn="${1%%=*}"
    _hrest="${1#*=}"
    _hk="${_hrest%%=*}"
    _hid="${_hrest#*=}"
    [ -n "$_hn" ] || die "--host: empty hostname in '$1'"
    case "$_hn" in
        *.*) die "--host: give a bare hostname, the domain is appended: $_hn" ;;
        *[!A-Za-z0-9-]*) die "--host: hostname may only contain letters, digits and '-': $_hn" ;;
    esac
    case "$_hid" in
        '') die "--host: empty HOSTID in '$1'" ;;
        *[!0-9A-Fa-f]*) die "--host: HOSTID must be hex digits: $_hid" ;;
    esac
    [ "${#_hid}" -le 16 ] || die "--host: HOSTID longer than 16 hex digits: $_hid"
    _hidn="$(norm_hostid "$_hid")"
    case "$_hidn" in
        0) die "--host: HOSTID 0 means 'assign dynamically' to odhcpd, not a reservation: $1" ;;
        1) die "--host: HOSTID 1 is the router's own LAN address: $1" ;;
    esac
    case "$_hk" in
        duid:*)
            _hkt='duid'
            _hk="${_hk#duid:}"
            _hkd="${_hk%%%*}"
            _hki="${_hk#"$_hkd"}"
            case "$_hkd" in
                '') die "--host: empty DUID in '$1'" ;;
                *[!0-9A-Fa-f]*) die "--host: DUID must be hex digits: $_hkd" ;;
            esac
            [ $(( ${#_hkd} % 2 )) -eq 0 ] || die "--host: DUID has an odd number of hex digits: $_hkd"
            # odhcpd reads the IAID as hex (strtoul base 16), 1-8 digits
            case "$_hki" in
                '') : ;;
                %*[!0-9A-Fa-f]*|%) die "--host: IAID after % must be 1-8 hex digits: $_hk" ;;
            esac
            [ "${#_hki}" -le 9 ] || die "--host: IAID longer than 8 hex digits: $_hk"
            _hk="$(printf '%s' "$_hkd$_hki" | tr 'A-F' 'a-f')" ;;
        [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f])
            _hkt='mac'
            _hk="$(printf '%s' "$_hk" | tr 'A-F' 'a-f')" ;;
        *) die "--host: '$_hk' is neither a MAC (aa:bb:cc:dd:ee:ff) nor duid:HEX[%IAID]" ;;
    esac
    # A DUID-LLT (type 1, 14 bytes) or DUID-LL (type 3, 10 bytes) ends in the
    # MAC, and odhcpd matches such a client by that MAC too - so a duid: line
    # and a MAC line can name the same machine. Compare them on the MAC.
    _hkmac="$(mac_in_key "$_hkt" "$_hk")"
    # one client, one suffix, one name: repeats are typos, not lists
    while IFS=' ' read -r _on _ot _ok _oh; do
        [ -n "$_on" ] || continue
        [ "$(lower_str "$_on")" = "$(lower_str "$_hn")" ] && die "--host: hostname given twice: $_hn"
        [ "$_ot $_ok" = "$_hkt $_hk" ] && die "--host: client given twice: $_hk"
        _omac="$(mac_in_key "$_ot" "$_ok")"
        [ -n "$_omac" ] && [ "$_omac" = "$_hkmac" ] && die "--host: $_hn and $_on name the same client (MAC $_hkmac)"
        [ "$(norm_hostid "$_oh")" = "$_hidn" ] && die "--host: HOSTID $_hid given twice ($_on, $_hn)"
    done <<HOSTS_EOF
$HOSTS
HOSTS_EOF
    HOSTS="${HOSTS}${HOSTS:+
}$_hn $_hkt $_hk $_hidn"
}

# One settings file instead of a long command line. Every line goes through the
# same add_*/validation path as the option it stands for, so nothing can enter
# through the file that the command line would refuse.
read_config() {
    _cf="$1"
    _cf_section=''
    [ -r "$_cf" ] || die "cannot read config file: $_cf"
    # shellcheck disable=SC2012
    _cf_mode="$(ls -ld "$_cf" 2>/dev/null | cut -c1-10)"
    while IFS= read -r _cf_line || [ -n "$_cf_line" ]; do
        _cf_line="${_cf_line%%#*}"
        _cf_line="$(printf '%s' "$_cf_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$_cf_line" ] || continue
        case "$_cf_line" in
            \[*\])
                _cf_section="${_cf_line#\[}"
                _cf_section="${_cf_section%\]}"
                _cf_section="$(printf '%s' "$_cf_section" | tr -d ' \t')"
                case "$_cf_section" in
                    peers|trusted|private-key|iface|lan|dns-domain|dns-router|dns-hosts|hosts|status-pkg|status-version|flags) : ;;
                    *) die "unknown section [$_cf_section] in $_cf" ;;
                esac
                continue ;;
        esac
        case "$_cf_section" in
            peers)          add_peer "$_cf_line" ;;
            trusted)        add_trusted "$_cf_line" ;;
            dns-hosts)      add_dns_host "$_cf_line" ;;
            hosts)          add_host "$_cf_line" ;;
            iface)          IFACE="$_cf_line" ;;
            lan)            LAN="$_cf_line" ;;
            dns-domain)     DNS_DOMAIN="$_cf_line" ;;
            dns-router)     DNS_ROUTER="$_cf_line" ;;
            status-pkg)     STATUS_PKG="$_cf_line" ;;
            status-version)
                status_valid_version "$_cf_line" || die "invalid status version '$_cf_line' in $_cf (expected vMAJOR.MINOR[.PATCH])"
                STATUS_VERSION="$_cf_line" ;;
            flags)
                case "$_cf_line" in
                    no-jumper)    DO_JUMPER=0 ;;
                    no-multicast) DO_MULTICAST=0 ;;
                    no-lan)       DO_LAN=0 ;;
                    no-firewall)  DO_FIREWALL=0 ;;
                    no-status)    DO_STATUS=0 ;;
                    dns)          DO_DNS=1 ;;
                    no-dns)       DO_DNS=0 ;;
                    dhcpv6)       LAN_MODE='dhcpv6' ;;
                    slaac)        LAN_MODE='slaac' ;;
                    *) die "unknown flag '$_cf_line' in [flags] of $_cf" ;;
                esac ;;
            private-key)
                [ -z "$CONFIG_KEY" ] || die "[private-key] holds more than one line, or was given twice: $_cf"
                CONFIG_KEY="$_cf_line"
                CONFIG_KEY_SRC="[private-key] in $_cf"
                case "$_cf_mode" in
                    ????------) : ;;
                    *) warn "config file holds the private key but is readable beyond its owner ($_cf_mode): $_cf" ;;
                esac ;;
            '') die "value before any [section] header in $_cf: $_cf_line" ;;
        esac
    done < "$_cf"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --config)      [ $# -ge 2 ] || die "--config needs a value";      read_config "$2"; shift 2 ;;
        --peer)        [ $# -ge 2 ] || die "--peer needs a value";        add_peer "$2";    shift 2 ;;
        --peers-file)  [ $# -ge 2 ] || die "--peers-file needs a value"
                       [ -r "$2" ]  || die "cannot read peers file: $2"
                       while IFS= read -r _line || [ -n "$_line" ]; do
                           _line="${_line%%#*}"
                           _line="$(printf '%s' "$_line" | tr -d ' \t\r')"
                           [ -n "$_line" ] && add_peer "$_line"
                       done < "$2"
                       shift 2 ;;
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
        --dhcpv6)      LAN_MODE='dhcpv6';  shift ;;
        --slaac)       LAN_MODE='slaac';   shift ;;
        --host)        [ $# -ge 2 ] || die "--host needs a value";        add_host "$2";     shift 2 ;;
        --status-pkg)  [ $# -ge 2 ] || die "--status-pkg needs a value";  STATUS_PKG="$2";  shift 2 ;;
        --status-version)
            [ $# -ge 2 ] || die "--status-version needs a value"
            status_valid_version "$2" || die "invalid status version '$2' (expected vMAJOR.MINOR[.PATCH])"
            STATUS_VERSION="$2"; shift 2 ;;
        --wait)        [ $# -ge 2 ] || die "--wait needs a value";        WAIT_SECS="$2";   shift 2 ;;
        -n|--dry-run)  DRY_RUN=1;          shift ;;
        -y|--yes)      ASSUME_YES=1;       shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage; die "unknown argument: $1" ;;
    esac
done

# A reservation only means something where odhcpd hands out the addresses. Refuse
# instead of silently writing config host sections nothing would act on.
if [ -n "$HOSTS" ]; then
    [ "$LAN_MODE" = 'dhcpv6' ] || die "--host needs --dhcpv6: in SLAAC mode the router does not assign addresses"
    [ "$DO_LAN" -eq 1 ] || die "--host cannot be combined with --no-lan"
fi

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
    case "$1" in
        # Keep the node identity out of /proc/<pid>/cmdline. The value is
        # validated as hex before this point, so no UCI quoting is required.
        *.private_key) printf 'set %s=%s\n' "$1" "$2" | uci -q batch ;;
        *)             uci set "$1=$2" ;;
    esac
}

uci_add_list() {
    [ "$DRY_RUN" -eq 1 ] && { printf '    would run: uci add_list %s=%s\n' "$1" "$2" >&2; return 0; }
    uci add_list "$1=$2"
}

uci_changes_redacted() {
    uci -q changes "$1" 2>/dev/null \
        | sed "s/^\([^=]*\.private_key\)=.*/\1='<REDACTED>'/"
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
validate_private_key() {
    _vpk_key="$1"
    _vpk_src="$2"
    # Never echo the value itself, not even in an error.
    case "${#_vpk_key}" in
        128) : ;;
        *) die "private key from $_vpk_src is ${#_vpk_key} characters, expected 128 hex" ;;
    esac
    case "$_vpk_key" in
        *[!0-9a-fA-F]*) die "private key from $_vpk_src contains non-hex characters" ;;
    esac
}

load_supplied_key() {
    _k=''
    # Copy then clear the exported value before choosing a source or spawning
    # helpers. A key file takes precedence, then a [private-key] section of
    # --config, then the environment; an ambient environment key must not
    # remain available to every later child process in the other cases either.
    _env_key="${YGG_PRIVATE_KEY-}"
    unset YGG_PRIVATE_KEY
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
    elif [ -n "$CONFIG_KEY" ]; then
        _k="$CONFIG_KEY"
        _src="$CONFIG_KEY_SRC"
    elif [ -n "$_env_key" ]; then
        _k="$(printf '%s' "$_env_key" | tr -d ' \t\r\n')"
        _src='the YGG_PRIVATE_KEY environment variable'
    else
        return 0
    fi

    validate_private_key "$_k" "$_src"

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
    [ "$CHANGED_DHCP" -eq 1 ] && { /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true; }
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

    # apk only. The design targets OpenWrt 25.12+, where apk is the package
    # manager; on an opkg release the package names and the yggdrasil netifd
    # proto differ enough that a run would fail somewhere less obvious than here.
    have apk || die "apk not found — this design targets OpenWrt 25.12 or newer"
    info "package manager: apk"

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

    if [ -n "$PEERS" ]; then
        info 'peers to configure (the existing set is replaced):'
        printf '%s\n' "$PEERS" | while IFS= read -r _p; do [ -n "$_p" ] && info "    $_p"; done
    else
        _have="$(uci show network 2>/dev/null | grep -c "=yggdrasil_${IFACE}_peer\$" || true)"
        if [ "${_have:-0}" -gt 0 ]; then
            info "no --peer given: the $_have existing peer section(s) are kept"
        else
            warn "no --peer given and no peer sections exist: the node will have an"
            warn "  address but no path into the network until peers are added"
        fi
    fi
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
            if uci -q changes "$_c" 2>/dev/null | grep -q .; then
                err "uncommitted UCI changes exist in '$_c':"
                uci_changes_redacted "$_c" >&2
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
        apk info -e "$_p" >/dev/null 2>&1 && continue
        _missing="$_missing $_p"
    done

    if [ -z "$_missing" ]; then
        # shellcheck disable=SC2086
        ok "all packages already installed:$(printf ' %s' $_want)"
        return 0
    fi

    info "installing:$_missing"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    would run: apk update\n' >&2
        printf '    would run: apk add%s\n' "$_missing" >&2
        return 0
    fi

    # shellcheck disable=SC2086
    apk update >/dev/null 2>&1 || warn "package index update failed — trying to install anyway"

    for _p in $_missing; do
        # shellcheck disable=SC2086
        if apk add "$_p" >/dev/null 2>&1; then
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

    # netifd sources /lib/netifd/proto/*.sh once, at startup. A handler installed
    # a moment ago is therefore invisible to the running daemon, and the Yggdrasil
    # interface would come up as proto 'none' with NO_DEVICE. Only a restart fixes
    # it, and it is done here, before the first UCI change: the restart drops
    # every interface for a few seconds, and doing it while nothing has been
    # written yet means a connection lost at that moment leaves the router exactly
    # as it was found, and re-running the script simply continues.
    if [ -n "$_missing" ] && [ "$DRY_RUN" -eq 0 ]; then
        info "restarting netifd so it picks up the freshly installed proto handler"
        info "  (interfaces drop for a few seconds; nothing has been changed yet)"
        /etc/init.d/network restart >/dev/null 2>&1 || die "network restart failed"
        _i=0
        while [ "$_i" -lt 30 ]; do
            ubus -t 2 wait_for network.interface 2>/dev/null && break
            _i=$((_i + 2)); sleep 2
        done
        sleep 2
        ok "netifd restarted"
    fi
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
    # Existing UCI state did not pass through load_supplied_key(). Validate the
    # selected value here as well before the unquoted, hex-only uci batch line.
    validate_private_key "$_priv" "the selected Yggdrasil identity"
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
    # A peer list given on the command line is the peer list: existing
    # sections are removed first, so a re-run cannot accumulate duplicates and
    # the configuration always matches what was asked for. Without one the
    # existing sections are left alone, so a re-run for another stage - a new
    # trusted address, the DNS module - does not need the peers repeated.
    _peer_type="yggdrasil_${IFACE}_peer"
    _n=0
    if [ -z "$PEERS" ]; then
        _have="$(uci show network 2>/dev/null | grep -c "=$_peer_type\$" || true)"
        if [ "${_have:-0}" -gt 0 ]; then
            info "peers: $_have existing section(s) kept (no --peer given)"
        else
            warn "no peers configured: the node gets an address but stays isolated"
            warn "  pick current peers from https://github.com/yggdrasil-network/public-peers"
            warn "  and re-run with --peer URI [--peer URI ...]"
        fi
    elif [ "$DRY_RUN" -eq 0 ]; then
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

    _existing_peers=''

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

        # Fallback for the case stage 1 cannot see: the handler was installed by
        # someone else since netifd last started, so this run had nothing to
        # install and did not restart it.
        _proto="$(ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@.proto' 2>/dev/null)"
        if [ "$_proto" != 'yggdrasil' ]; then
            warn "netifd reports proto='${_proto:-unset}' for '$IFACE'"
            warn "restarting netifd so it loads the yggdrasil proto handler"
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

# <prefix>::HOSTID as one canonical (RFC 5952) address. $1 = prefix like
# 303:170f:3ab2:166e::/64, $2 = hostid hex digits. A hextet holds four digits, so
# a wide hostid is split, not concatenated onto the prefix as a string.
reserved_addr() {
    _ra_pfx="${1%%/*}"
    _ra_pfx="${_ra_pfx%%::*}"
    _ra_id="$(printf '%016s' "$2" | tr ' ' '0')"
    printf '%s %s\n' "$_ra_pfx" "$_ra_id" | awk '{
        n = split($1, h, ":")
        for (i = n + 1; i <= 4; i++) h[i] = "0"
        for (i = 1; i <= 4; i++) h[4 + i] = substr($2, 4 * i - 3, 4)
        for (i = 1; i <= 8; i++) { sub(/^0+/, "", h[i]); if (h[i] == "") h[i] = "0" }
        best = 0; bs = 0
        for (i = 1; i <= 8; i++) {
            if (h[i] != "0") continue
            j = i; while (j <= 8 && h[j] == "0") j++
            if (j - i > best) { best = j - i; bs = i }
            i = j
        }
        out = ""
        if (best >= 2) {
            for (i = 1; i < bs; i++) out = out h[i] ":"
            out = out ":"
            for (i = bs + best; i <= 8; i++) out = out (i == bs + best ? "" : ":") h[i]
            if (bs == 1) out = ":" out
        } else {
            for (i = 1; i <= 8; i++) out = out (i > 1 ? ":" : "") h[i]
        }
        print out
    }'
}

# The suffix odhcpd derives for a config host that has an IPv4 address but no
# hostid: the last octet's decimal digits read as hex nibbles (.235 -> ::235).
implicit_hostid() {
    norm_hostid "${1##*.}"
}

# One line per existing config host: "<section> <hostid-or-empty> <macs> <duid>".
# Read once, so the collision check and the update path see the same picture.
existing_hosts() {
    uci show dhcp 2>/dev/null | awk -F= '
        $1 ~ /^dhcp\.[^.]+$/ && $2 == "host" { sec[$1] = 1; order[++n] = $1; next }
        {
            split($1, k, ".")
            if (k[3] == "") next
            id = k[1] "." k[2]
            v = $2; gsub(/^'\''|'\''$/, "", v); gsub(/'\'' '\''/, ",", v)
            if (k[3] == "hostid") hid[id] = v
            else if (k[3] == "ip") ip[id] = v
            else if (k[3] == "mac") mac[id] = tolower(v)
            else if (k[3] == "duid") duid[id] = tolower(v)
            else if (k[3] != "name" && k[3] != "dns" && k[3] != "leasetime") extra[id] = extra[id] " " k[3]
        }
        END {
            for (i = 1; i <= n; i++) {
                id = order[i]; if (!(id in sec)) continue
                printf "%s|%s|%s|%s|%s|%s\n", id, hid[id], ip[id], mac[id], duid[id], extra[id]
            }
        }'
}

# Not written by this script, but they become live IPv6 reservations the moment
# odhcpd serves DHCPv6 - the operator should know which suffixes those are.
report_implicit_hosts() {
    while IFS='|' read -r _es _ehid _eip _emac _eduid _eextra; do
        [ -n "$_es" ] && [ -z "$_ehid" ] && [ -n "$_eip" ] || continue
        info "existing ${_es#dhcp.} (${_emac:-no mac}, ip $_eip) implies suffix ::$(implicit_hostid "$_eip")"
    done <<EH_EOF
$(existing_hosts)
EH_EOF
    return 0
}

apply_hosts() {
    [ -n "$HOSTS" ] || return 0
    _eh="$(existing_hosts)"

    # Every suffix odhcpd will hand out from this prefix, ours and the ones the
    # existing sections already imply, must be distinct.
    while IFS=' ' read -r _hn _hkt _hk _hid; do
        [ -n "$_hn" ] || continue
        while IFS='|' read -r _es _ehid _eip _emac _eduid _eextra; do
            [ -n "$_es" ] || continue
            # the section this reservation will update may hold its own suffix
            [ "$_hkt" = 'mac'  ] && [ "$_emac"  = "$_hk" ] && continue
            [ "$_hkt" = 'duid' ] && [ "$_eduid" = "$_hk" ] && continue
            if [ -n "$_ehid" ]; then
                [ "$_ehid" = 'ignore' ] && continue
                _eid="$(norm_hostid "$_ehid")"; _why="hostid $_ehid"
            elif [ -n "$_eip" ]; then
                _eid="$(implicit_hostid "$_eip")"; _why="implicit, from ip $_eip"
            else
                continue
            fi
            [ "$_eid" = "$_hid" ] && die "--host $_hn: suffix ::$_hid is already taken by ${_es#dhcp.} ($_why)"
        done <<EH_EOF
$_eh
EH_EOF
    done <<HOSTS_EOF
$HOSTS
HOSTS_EOF

    _touched=' '
    while IFS=' ' read -r _hn _hkt _hk _hid; do
        [ -n "$_hn" ] || continue
        _match=''; _nmatch=0
        while IFS='|' read -r _es _ehid _eip _emac _eduid _eextra; do
            [ -n "$_es" ] || continue
            if [ "$_hkt" = 'mac' ]; then
                case ",$_emac," in *",$_hk,"*) _match="$_es|$_emac|$_eextra"; _nmatch=$((_nmatch + 1)) ;; esac
            else
                [ "$_eduid" = "$_hk" ] && { _match="$_es|$_emac|$_eextra"; _nmatch=$((_nmatch + 1)); }
            fi
        done <<EH_EOF
$_eh
EH_EOF
        [ "$_nmatch" -le 1 ] || die "--host $_hn: $_hk appears in $_nmatch config host sections — resolve that in Network -> DHCP and DNS first"
        _addr="$(reserved_addr "$YGG_PREFIX" "$_hid")"
        if [ -n "$_match" ]; then
            _es="${_match%%|*}"; _mrest="${_match#*|}"; _emac="${_mrest%%|*}"; _eextra="${_mrest#*|}"
            case "$_emac" in *,*) die "--host $_hn: ${_es#dhcp.} lists several MACs — not touching a shared section" ;; esac
            [ -z "${_eextra# }" ] || die "--host $_hn: ${_es#dhcp.} carries extra options (${_eextra# }) — edit it by hand instead"
            case "$_touched" in *" $_es "*) die "--host $_hn: ${_es#dhcp.} was already updated for another --host line — one section, one reservation" ;; esac
            uci_set "$_es.name" "$_hn"
            uci_set "$_es.hostid" "$_hid"
            info "reservation $_hn -> $_addr (updated ${_es#dhcp.})"
        else
            _es="dhcp.ygg_host_$(printf '%s' "$_hn" | tr -c 'A-Za-z0-9' '_')"
            # The section id is derived from the name. If it already exists it
            # belongs to a different client (this one matched nothing above),
            # and 'uci set' would quietly turn it into this reservation.
            case "
$_eh" in
                *"
$_es|"*)
                    die "--host $_hn: section ${_es#dhcp.} already exists for another client — rename the reservation or remove that section" ;;
                *)
                    uci_set "$_es" 'host'
                    uci_set "$_es.name" "$_hn"
                    uci_set "$_es.$_hkt" "$_hk"
                    uci_set "$_es.hostid" "$_hid"
                    info "reservation $_hn -> $_addr (new ${_es#dhcp.})" ;;
            esac
        fi
        _touched="$_touched$_es "
    done <<HOSTS_EOF
$HOSTS
HOSTS_EOF

    return 0
}

stage_lan() {
    [ "$DO_LAN" -eq 1 ] || { info "skipping LAN stage (--no-lan)"; return 0; }
    FAILED_STAGE='LAN routed /64 and RA'
    if [ "$LAN_MODE" = 'dhcpv6' ]; then
        step "Stage 4 — LAN routed /64, RA and stateful DHCPv6"
    else
        step "Stage 4 — LAN routed /64 and SLAAC-only RA"
    fi

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
    uci_set "dhcp.$LAN.ra" 'server'
    uci_set "dhcp.$LAN.ra_default" '2'
    uci_set "dhcp.$LAN.ra_preference" 'medium'
    uci_del "dhcp.$LAN.ra_flags"
    if [ "$LAN_MODE" = 'dhcpv6' ]; then
        # Settings this script never writes but which would silently defeat
        # the mode: refuse rather than override an operator's choice.
        [ "$(uci -q get "dhcp.$LAN.dhcpv6_na")" != '0' ] \
            || die "dhcp.$LAN.dhcpv6_na=0 disables address assignment — remove it or stay on --slaac"
        [ "$(uci -q get "dhcp.$LAN.ra_offlink")" != '1' ] \
            || die "dhcp.$LAN.ra_offlink=1 clears the on-link flag — remove it first"
        uci_set "dhcp.$LAN.dhcpv6" 'server'
        uci_set "dhcp.$LAN.ra_slaac" '0'
        uci_add_list "dhcp.$LAN.ra_flags" 'managed-config'
        uci_add_list "dhcp.$LAN.ra_flags" 'other-config'
        info "DHCPv6 server, RA=server with M/O flags, A flag off"
        report_implicit_hosts
        if [ -n "$HOSTS" ]; then
            # Same lock the status module takes around its config host edits.
            if have flock && [ "$DRY_RUN" -eq 0 ]; then
                exec 9>>/var/lock/yggdrasil-status-dhcp.lock
                flock -n 9 || die "another process is editing DHCP hosts (lock busy) — retry in a moment"
            fi
            apply_hosts
        fi
    else
        uci_set "dhcp.$LAN.dhcpv6" 'disabled'
        uci_set "dhcp.$LAN.ra_slaac" '1'
        uci_add_list "dhcp.$LAN.ra_flags" 'none'
        info "DHCPv6 disabled, RA=server, SLAAC-only"
    fi

    if [ "$DRY_RUN" -eq 0 ]; then
        uci commit network || die "uci commit network failed"
        uci commit dhcp    || die "uci commit dhcp failed"
        [ -n "$HOSTS" ] && have flock && exec 9>&-
        /etc/init.d/network reload >/dev/null 2>&1 || die "network reload failed"
        /etc/init.d/odhcpd restart >/dev/null 2>&1 || die "odhcpd restart failed"
        # config host also feeds dnsmasq's DHCPv4 side; the DNS stage restarts
        # it too, but --no-dns must not leave a stale generated config behind.
        if [ -n "$HOSTS" ] && [ "$DO_DNS" -eq 0 ]; then
            /etc/init.d/dnsmasq restart >/dev/null 2>&1 || die "dnsmasq restart failed"
        fi
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
    # $1 = fully qualified name, $2 = address, $3 = section (default: derived)
    _sec="${3:-$(dns_section "$1" "$2")}"
    uci_set "dhcp.$_sec" 'domain'
    uci_set "dhcp.$_sec.name" "$1"
    uci_set "dhcp.$_sec.ip" "$2"
    info "record $1 -> $2"
}

# Records derived from --host reservations live under their own prefix and are
# rebuilt from scratch on every run: a reservation that is no longer supplied
# must not leave a name pointing at a suffix nobody holds any more.
rsv_purge_all() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '    would run: drop existing ygg_rsv_* records\n' >&2
        return 0
    fi
    uci show dhcp 2>/dev/null \
        | sed -n 's/^dhcp\.\(ygg_rsv_[A-Za-z0-9_]*\)=domain$/\1/p' \
        | while IFS= read -r _s; do
              [ -n "$_s" ] && uci -q delete "dhcp.$_s"
          done
    return 0
}

dns_reservations() {
    rsv_purge_all
    [ -n "$HOSTS" ] || return 0
    while IFS=' ' read -r _hn _hkt _hk _hid; do
        [ -n "$_hn" ] || continue
        dns_record "${_hn}.${DNS_DOMAIN}" "$(reserved_addr "$YGG_PREFIX" "$_hid")" \
            "ygg_rsv_$(printf '%s' "$_hn" | tr -c 'A-Za-z0-9' '_')"
    done <<HOSTS_EOF
$HOSTS
HOSTS_EOF
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
    dns_reservations

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

# $3 is only ever set for the fixed api.github.com lookup below. A release
# asset download redirects to a different host, so a credential must never be
# attached to one. uclient-fetch has no header option and is skipped in that
# branch rather than silently dropping the header.
status_fetch() { # $1 = HTTPS URL, $2 = destination, $3 = optional request header
    if [ -n "${3:-}" ]; then
        wget -q --header="$3" -O "$2" "$1" 2>/dev/null \
            || curl -fsSL -H "$3" -o "$2" "$1" 2>/dev/null
    else
        wget -q -O "$2" "$1" 2>/dev/null \
            || uclient-fetch -q -O "$2" "$1" 2>/dev/null \
            || curl -fsSL -o "$2" "$1" 2>/dev/null
    fi
}

status_valid_version() { # $1 = candidate version label
    printf '%s\n' "$1" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?$'
}

# Read exactly one digest from a checksum file. A file naming several artifacts
# is ambiguous, and a path inside it is never followed.
status_expected_digest() { # $1 = checksum file
    [ -r "$1" ] || { warn "required checksum missing: $1"; return 1; }
    sed_digest="$(awk 'NF { n++; digest=$1 } END { if (n != 1) exit 1; print digest }' "$1")" || {
        warn "checksum file must contain exactly one entry: $1"
        return 1
    }
    printf '%s\n' "$sed_digest"
}

# Ask GitHub for the newest published release. Only a status tag in the expected
# shape is accepted, so a release name can never steer the download path.
# Anonymous api.github.com calls are limited per source IP. A shared address —
# CI runners, or a router behind CGNAT — can exhaust that budget through no
# fault of its own, and release discovery then fails for an hour. GITHUB_TOKEN
# raises the limit. It is optional and off by default; note that it reaches
# wget as a process argument, so set it where that is acceptable.
status_resolve_version() {
    srv_auth=''
    [ -n "${GITHUB_TOKEN:-}" ] && srv_auth="Authorization: Bearer ${GITHUB_TOKEN}"
    srv_tmp="$(mktemp "${TMPDIR:-/tmp}/ygg-release.XXXXXX")" || return 1
    if ! status_fetch "$STATUS_API" "$srv_tmp" "$srv_auth"; then
        rm -f "$srv_tmp"
        return 1
    fi
    # jsonfilter is a router dependency; the sed path keeps this function usable
    # on a plain host, and both results go through the same strict validation.
    if have jsonfilter; then
        srv_tag="$(jsonfilter -i "$srv_tmp" -e '@.tag_name' 2>/dev/null)"
    else
        srv_tag="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$srv_tmp" | head -n 1)"
    fi
    rm -f "$srv_tmp"
    case "$srv_tag" in
        status-v*) srv_version="${srv_tag#status-}" ;;
        *) return 1 ;;
    esac
    status_valid_version "$srv_version" || return 1
    printf '%s\n' "$srv_version"
}

status_verify() { # $1 = tarball, $2 = required SHA-256
    sv_expected="$(printf '%s' "$2" | tr 'A-F' 'a-f')"
    case "$sv_expected" in
        ''|*[!0-9a-f]*) warn "missing or invalid status package SHA-256"; return 1 ;;
    esac
    [ "${#sv_expected}" -eq 64 ] || { warn "invalid status package SHA-256 length"; return 1; }
    have sha256sum || { warn "sha256sum missing - refusing unverified status package"; return 1; }
    sv_result="$(sha256sum "$1" 2>/dev/null)" || { warn "cannot hash status package"; return 1; }
    sv_got="${sv_result%% *}"
    [ "$sv_expected" = "$sv_got" ] || {
        warn "status module checksum mismatch - refusing to install"
        warn "  expected $sv_expected"
        warn "  got      $sv_got"
        return 1
    }
    ok "checksum verified"
}

status_acquire() { # $1 = destination, $2 = optional checkout package directory
    sa_dest="$1"
    sa_cache="$2"

    if [ -n "$STATUS_PKG" ]; then
        [ -r "$STATUS_PKG" ] || { warn "cannot read $STATUS_PKG"; return 1; }
        sa_expected="$(status_expected_digest "$STATUS_PKG.sha256")" || return 1
        cp "$STATUS_PKG" "$sa_dest" || { warn "cannot copy local status package"; return 1; }
        info "using local package $STATUS_PKG"
        status_verify "$sa_dest" "$sa_expected"
        return $?
    fi

    if [ -z "$STATUS_VERSION" ]; then
        STATUS_VERSION="$(status_resolve_version)" || {
            warn "cannot determine the newest status release"
            warn "  use --status-version VER for a known release, or --status-pkg PATH"
            return 1
        }
        info "newest published status release is $STATUS_VERSION"
    fi

    sa_name="yggdrasil-status-$STATUS_VERSION.tar.gz"
    STATUS_BASE="$STATUS_RELEASE_BASE/status-$STATUS_VERSION"

    # Preserve offline installs from a checkout. A cached archive still has to
    # prove its bytes with its own checksum file; it is not trusted for being
    # local. Custom builds must use --status-pkg explicitly.
    if [ -r "$sa_cache/$sa_name" ]; then
        sa_expected="$(status_expected_digest "$sa_cache/$sa_name.sha256")" || return 1
        cp "$sa_cache/$sa_name" "$sa_dest" || { warn "cannot copy cached status package"; return 1; }
        info "using $STATUS_VERSION from the local checkout"
        status_verify "$sa_dest" "$sa_expected"
        return $?
    fi

    info "downloading $STATUS_BASE/$sa_name"
    status_fetch "$STATUS_BASE/$sa_name" "$sa_dest" \
        || { warn "status package download failed"; return 1; }
    # No unverified install: without the published checksum this stops here.
    status_fetch "$STATUS_BASE/$sa_name.sha256" "$sa_dest.sha256" \
        || { warn "published checksum unavailable - refusing unverified package"; return 1; }
    sa_expected="$(status_expected_digest "$sa_dest.sha256")" || return 1
    status_verify "$sa_dest" "$sa_expected"
}

stage_status() {
    [ "$DO_STATUS" -eq 1 ] || { info "skipping status module (--no-status)"; return 0; }
    FAILED_STAGE='LuCI status module'
    step "Stage 7 - LuCI status module"
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ -n "$STATUS_PKG" ]; then
            info "would install verified status module from $STATUS_PKG"
        elif [ -n "$STATUS_VERSION" ]; then
            info "would install verified status module $STATUS_VERSION from $STATUS_RELEASE_BASE"
        else
            info "would install the newest published status module from $STATUS_RELEASE_BASE"
        fi
        return 0
    fi

    # Isolated cleanup traps must not replace the parent deployer's rollback traps.
    (
        ss_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ygg-status-deploy.XXXXXX")" \
            || { warn "cannot create private status workspace"; exit 0; }
        trap 'rm -rf "$ss_tmp"' EXIT
        trap 'exit 1' HUP INT TERM
        ss_tgz="$ss_tmp/status.tar.gz"
        if ! status_acquire "$ss_tgz" "$(dirname "$0")/../packages"; then
            warn "status module skipped; core routing is unaffected"
            exit 0
        fi
        ( cd "$ss_tmp" && tar -xzf "$ss_tgz" ) \
            || { warn "tar extraction failed - skipping status module"; exit 0; }
        ss_inst="$(find "$ss_tmp" -name install.sh -type f 2>/dev/null | head -n1)"
        [ -n "$ss_inst" ] || { warn "install.sh not found in the package - skipping"; exit 0; }
        info "running $ss_inst (it has its own backup + rollback)"
        if sh "$ss_inst"; then
            ok "status module installed"
        else
            warn "status module installer failed; check its rollback messages - core routing is unaffected"
            exit 0
        fi
        if ubus -v list luci.yggdrasil-status >/dev/null 2>&1; then
            ok "RPC object luci.yggdrasil-status is registered"
        else
            warn "RPC object luci.yggdrasil-status not visible - check 'logread | grep rpcd'"
        fi
    )
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
        check 'RA'             'server'   "$(uci -q get "dhcp.$LAN.ra")"
        check 'RA default'     '2'        "$(uci -q get "dhcp.$LAN.ra_default")"
        check 'RA preference'  'medium'   "$(uci -q get "dhcp.$LAN.ra_preference")"
        # a UCI list comes back space-joined; compare as a set, not as one string
        _raf="$(uci -q get "dhcp.$LAN.ra_flags" | tr ' ' '\n' | sort | tr '\n' ' ')"
        if [ "$LAN_MODE" = 'dhcpv6' ]; then
            check 'DHCPv6'         'server'   "$(uci -q get "dhcp.$LAN.dhcpv6")"
            check 'RA SLAAC'       '0'        "$(uci -q get "dhcp.$LAN.ra_slaac")"
            check 'RA flags'       'managed-config other-config ' "$_raf"
            check 'odhcpd running' 'yes' "$(pidof odhcpd >/dev/null 2>&1 && echo yes || echo no)"
        else
            check 'DHCPv6'         'disabled' "$(uci -q get "dhcp.$LAN.dhcpv6")"
            check 'RA SLAAC'       '1'        "$(uci -q get "dhcp.$LAN.ra_slaac")"
            check 'RA flags'       'none '    "$_raf"
        fi
        check 'ula_prefix removed' ''     "$(uci -q get network.globals.ula_prefix)"
        if [ -n "$HOSTS" ]; then
            _eh="$(existing_hosts)"
            while IFS=' ' read -r _hn _hkt _hk _hid; do
                [ -n "$_hn" ] || continue
                _got=''
                while IFS='|' read -r _es _ehid _eip _emac _eduid _eextra; do
                    [ -n "$_es" ] || continue
                    if [ "$_hkt" = 'mac' ]; then
                        case ",$_emac," in *",$_hk,"*) _got="$_ehid" ;; esac
                    else
                        [ "$_eduid" = "$_hk" ] && _got="$_ehid"
                    fi
                done <<EH_EOF
$_eh
EH_EOF
                [ -n "$_got" ] && _got="$(norm_hostid "$_got")"
                check "reservation $_hn" "$_hid" "$_got"
            done <<HOSTS_EOF
$HOSTS
HOSTS_EOF
            # A lease proves the path end to end, but the client may simply be
            # off right now, so its absence is information, not a failed invariant.
            _leases="$(ubus call dhcp ipv6leases 2>/dev/null | jsonfilter -e '@.device[*].leases[*]["ipv6-addr"][*].address' 2>/dev/null | tr '\n' ' ')"
            if [ -n "$_leases" ]; then
                ok "bound DHCPv6 leases: $_leases"
            else
                warn "no DHCPv6 lease bound yet — a client obtains one when it next asks (reconnect, renew, reboot)"
            fi
        fi
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
    if [ "$DO_LAN" -eq 1 ] && [ "$LAN_MODE" = 'dhcpv6' ]; then
        printf '      %s  (addresses assigned by DHCPv6; no SLAAC)\n\n' "$YGG_PREFIX" >&2
    else
        printf '      %s\n\n' "$YGG_PREFIX" >&2
    fi
    if [ -n "$HOSTS" ]; then
        printf '  Reserved LAN addresses\n' >&2
        while IFS=' ' read -r _hn _hkt _hk _hid; do
            [ -n "$_hn" ] || continue
            printf '      %-20s %s\n' "$_hn" "$(reserved_addr "$YGG_PREFIX" "$_hid")" >&2
        done <<HOSTS_EOF
$HOSTS
HOSTS_EOF
        printf '\n' >&2
    fi

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
