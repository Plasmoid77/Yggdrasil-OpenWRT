#!/bin/sh
# shellcheck disable=SC2034,SC2317,SC2329
# The deployer's option loop and helpers are extracted with sed/awk and
# evaluated here, which hides their references from ShellCheck.
#
# Deployer 2.0 adds the routed /64 beside the LAN's own prefixes and keeps the
# stock RA/DHCPv6 configuration. This checks the option surface (the 1.x mode
# switches are refused), the LAN inspection and its --host preconditions, the
# reservation grammar, the address arithmetic, the collision check against
# existing config host sections, the UCI values the LAN stage writes, and the
# LAN-to-Yggdrasil firewall rule.

set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/deploy/deploy-openwrt-yggdrasil.sh"
TMP="$(mktemp -d /tmp/ygg-lanoverlay-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

extract_function() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\)" { found = 1 }
        found { print }
        found && /^}$/ { exit }
    ' "$SCRIPT"
}

eval "$(sed -n '/^set -u$/,/^VERSION=/p' "$SCRIPT" | sed '/^set -u$/d')"
eval "$(sed -n '/^# -* defaults -*$/,/^usage() {$/p' "$SCRIPT" | sed '$d')"
for f in add_peer add_trusted add_dns_host lower_str is_mac norm_duid norm_duid_opt duid_in_key mac_in_key norm_hostid add_host status_valid_version read_config \
         inspect_lan lan_has_ygg_prefix lan_zone reserved_addr implicit_hostid existing_hosts section_is_client report_implicit_hosts apply_hosts stage_lan fw_rule_trusted stage_firewall; do
    body="$(extract_function "$f")"
    [ -n "$body" ] || { echo "FAIL: function $f not found in deployer" >&2; exit 1; }
    eval "$body"
done
PARSER="$(sed -n '/^while \[ \$# -gt 0 \]; do$/,/^done$/p' "$SCRIPT")"
POSTCHECK="$(sed -n '/^# A reservation only means something/,/^# Ask for the Yggdrasil/p' "$SCRIPT" | sed '$d')"
[ -n "$POSTCHECK" ] || { echo 'FAIL: --host post-parse check not found' >&2; exit 1; }

DIED=''; WARNED=''; INFOD=''; ERRED=''
die()   { DIED="${DIED}${*}
"; }
err()   { ERRED="${ERRED}${*}
"; }
warn()  { WARNED="${WARNED}${*}
"; }
info()  { INFOD="${INFOD}${*}
"; }
ok()    { :; }
step()  { :; }
usage() { :; }
have()  { return 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }
reset() {
    DIED=''; WARNED=''; INFOD=''; ERRED=''; HOSTS=''; DNS_HOSTS=''; TRUSTED=''; DO_LAN=1; DO_DNS=1; DO_FIREWALL=1
    DO_LAN_FORWARD=1
    CUR_IP6ASSIGN=''; CUR_IP6CLASS=''; CUR_ULA=''; CUR_DHCPV6=''; CUR_RA_SLAAC=''; CUR_RA_FLAGS=''
}

# 1. option surface: the 1.x mode switches are refused with an explanation,
#    the 2.0 switches and [flags] entries are applied
reset; set --; eval "$PARSER"
[ "$DO_LAN_FORWARD" = 1 ] || fail "2.0 defaults changed"
reset; set -- --dhcpv6; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'from 1.x' || fail "--dhcpv6 was not refused: $DIED"
reset; set -- --slaac; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'from 1.x' || fail "--slaac was not refused: $DIED"
reset; set -- --no-lan-forward; eval "$PARSER"
[ -z "$DIED" ] || fail "2.0 switches rejected: $DIED"
[ "$DO_LAN_FORWARD" = 0 ] || fail "--no-lan-forward not applied"
umask 077
printf '[flags]\nno-lan-forward\n[hosts]\nnas=6c:92:bf:2f:aa:28=10\n' > "$TMP/overlay.conf"
reset; set -- --config "$TMP/overlay.conf"; eval "$PARSER"
[ -z "$DIED" ] || fail "2.0 settings file rejected: $DIED"
[ "$DO_LAN_FORWARD" = 0 ] || fail "[flags] entry not applied"
[ "$HOSTS" = 'nas mac 6c:92:bf:2f:aa:28 10' ] || fail "[hosts] line not applied: '$HOSTS'"
printf '[flags]\ndhcpv6\n' > "$TMP/legacy.conf"
reset; set -- --config "$TMP/legacy.conf"; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'from 1.x' || fail "[flags] dhcpv6 was not refused: $DIED"
echo 'PASS: 2.0 option surface, 1.x switches refused'

# 1b. LAN inspection: the LAN is described, --host preconditions are settled
#     before anything is written
LAN='lan'; IFACE='ygg0'
get_ygg_prefix() { printf '%s\n' "$YGG_PFX_LINE"; }
# the router's LAN values, one variable per option
uci() {
    [ "$1 $2" = '-q get' ] || return 1
    case "$3" in
        network.lan.ip6assign) printf '%s\n' "$U_IP6ASSIGN" ;;
        network.lan.ip6class)  printf '%s\n' "$U_IP6CLASS" ;;
        network.globals.ula_prefix) printf '%s\n' "$U_ULA" ;;
        dhcp.lan.dhcpv6)    printf '%s\n' "$U_DHCPV6" ;;
        dhcp.lan.ra_slaac)  printf '%s\n' "$U_RA_SLAAC" ;;
        dhcp.lan.ra_flags)  printf '%s\n' "$U_RA_FLAGS" ;;
        dhcp.lan.dhcpv6_na) printf '%s\n' "${U_DHCPV6_NA:-}" ;;
        dhcp.lan.ra_offlink) printf '%s\n' "${U_RA_OFFLINK:-}" ;;
        *) return 1 ;;
    esac
}
stock() { U_IP6ASSIGN=60; U_IP6CLASS=''; U_ULA='fd75:921a:ca44::/48'; U_DHCPV6=server; U_RA_SLAAC=1; U_RA_FLAGS='managed-config other-config'; U_DHCPV6_NA=''; U_RA_OFFLINK=''; YGG_PFX_LINE=''; }
stock; reset; inspect_lan
[ -z "$DIED" ] || fail "stock router died: $DIED"
[ "$LAN_YGG_CLASS" = ygg0 ] || fail "without a prefix the class must fall back to the interface name: $LAN_YGG_CLASS"
[ "$CUR_IP6ASSIGN" = 60 ] && [ "$CUR_ULA" = 'fd75:921a:ca44::/48' ] || fail "LAN values not read"
printf '%s' "$INFOD" | grep -q 'ULA fd75:921a:ca44::/48 kept' || fail "ULA not reported: $INFOD"
# ip6class variants are described
stock; U_IP6CLASS='wan6 local'; YGG_PFX_LINE='303::/64 ygg0'; reset; inspect_lan
printf '%s' "$INFOD" | grep -q "'ygg0' added to it" || fail "custom ip6class not described: $INFOD"
stock; U_IP6CLASS='ygg0 local'; YGG_PFX_LINE='303::/64 ygg0'; reset; inspect_lan
printf '%s' "$INFOD" | grep -q "admits 'ygg0'" || fail "admitting ip6class not described: $INFOD"
# --host preconditions, settled before anything is written
stock; U_DHCPV6=disabled; reset; HOSTS='a mac 6c:92:bf:2f:aa:28 10'; inspect_lan
printf '%s' "$DIED" | grep -q "needs the LAN's DHCPv6 server" || fail "--host on a LAN without DHCPv6 accepted: $DIED"
stock; U_DHCPV6=''; reset; HOSTS='a mac 6c:92:bf:2f:aa:28 10'; inspect_lan
printf '%s' "$DIED" | grep -q "found '<unset>'" || fail "--host with dhcpv6 unset accepted: $DIED"
stock; reset; HOSTS='a mac 6c:92:bf:2f:aa:28 10'; inspect_lan
[ -z "$DIED" ] || fail "--host on a stock router refused: $DIED"
stock; U_DHCPV6_NA=0; reset; HOSTS='a mac 6c:92:bf:2f:aa:28 10'; inspect_lan
printf '%s' "$DIED" | grep -q 'dhcpv6_na=0' || fail "dhcpv6_na=0 was not refused"
stock; U_RA_OFFLINK=1; reset; HOSTS='a mac 6c:92:bf:2f:aa:28 10'; inspect_lan
printf '%s' "$DIED" | grep -q 'ra_offlink=1' || fail "ra_offlink=1 was not refused"
stock; U_DHCPV6_NA=0; reset; inspect_lan
[ -z "$DIED" ] || fail "without --host the reservation preconditions must not apply: $DIED"
unset -f uci
echo 'PASS: LAN inspection and --host preconditions'

# 2. reservation grammar
reset; set -- \
    --host 'Nas-1=6C:92:BF:2F:AA:28=010' \
    --host 'bmc=duid:00030001000000000000%2B67=20' \
    --host 'cam=duid:000100012F3A02A76c92bf2faa29=ABCD1234'
eval "$PARSER"
[ -z "$DIED" ] || fail "valid --host lines rejected: $DIED"
printf '%s\n' "$HOSTS" | grep -qxF 'Nas-1 mac 6c:92:bf:2f:aa:28 10' || fail "MAC/hostid not normalised: $HOSTS"
printf '%s\n' "$HOSTS" | grep -qxF 'bmc duid 00030001000000000000%2b67 20' || fail "duid%IAID form not kept: $HOSTS"
printf '%s\n' "$HOSTS" | grep -qxF 'cam duid 000100012f3a02a76c92bf2faa29 abcd1234' || fail "duid form not normalised: $HOSTS"
# MAC and DUID together, for a client whose DUID carries no MAC
reset; set -- --host 'Laptop=3C:E1:A1:41:52:D0+duid:0004ECBCBFB80EF2996849BCA6B0D0A6FFCE%0000A=20'; eval "$PARSER"
[ -z "$DIED" ] || fail "MAC+duid form rejected: $DIED"
[ "$HOSTS" = 'Laptop mac+duid 3c:e1:a1:41:52:d0+0004ecbcbfb80ef2996849bca6b0d0a6ffce%a 20' ] || fail "MAC+duid form not normalised: $HOSTS"
[ "$(mac_in_key mac+duid '3c:e1:a1:41:52:d0+0004ecbc%a')" = '3c:e1:a1:41:52:d0' ] || fail "mac_in_key on the combined form"
[ "$(duid_in_key mac+duid '3c:e1:a1:41:52:d0+0004ecbc%a')" = '0004ecbc%a' ] || fail "duid_in_key on the combined form"
[ -z "$(duid_in_key mac '3c:e1:a1:41:52:d0')" ] || fail "duid_in_key invented a DUID for a MAC"
reset; set -- --host 'a=3c:e1:a1:41:52+duid:0004ecbcbfb80ef2996849bca6b0d0a6ffce=20'; eval "$PARSER"
printf '%s' "$DIED" | grep -q "before '+duid:' is not a MAC" || fail "bad MAC before +duid accepted"
reset; set -- --host 'a=3c:e1:a1:41:52:d0+duid:0004ecbcbfb80ef2996849bca6b0d0a6ffce=20' --host 'b=duid:0004ECBCBFB80EF2996849BCA6B0D0A6FFCE=21'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'same client (DUID 0004ecbcbfb80ef2996849bca6b0d0a6ffce)' || fail "the same DUID under two forms accepted: $DIED"
reset; set -- --host 'a=3c:e1:a1:41:52:d0+duid:0004ecbcbfb80ef2996849bca6b0d0a6ffce=20' --host 'b=3c:e1:a1:41:52:d0=21'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'same client (MAC 3c:e1:a1:41:52:d0)' || fail "the same MAC under two forms accepted: $DIED"
echo 'PASS: --host accepts MAC, DUID and DUID%IAID forms and normalises them'

for case_ in 'no-hostid:a=6c:92:bf:2f:aa:28' 'bad-mac:a=6c:92:bf:2f:aa=10' 'short-mac:a=6c:92:bf=10' \
             'zero:a=6c:92:bf:2f:aa:28=0' 'zero-padded:a=6c:92:bf:2f:aa:28=000' 'one:a=6c:92:bf:2f:aa:28=1' \
             'too-long:a=6c:92:bf:2f:aa:28=12345678901234567' 'not-hex:a=6c:92:bf:2f:aa:28=10g' \
             'dotted-name:a.b=6c:92:bf:2f:aa:28=10' 'bad-name:a_b=6c:92:bf:2f:aa:28=10' \
             'empty-duid:a=duid:=10' 'odd-duid:a=duid:abc=10' 'bad-iaid:a=duid:0004ecbcbfb80ef2996849bca6b0d0a6ffce%zz=10' \
             'long-iaid:a=duid:0004ecbcbfb80ef2996849bca6b0d0a6ffce%123456789=10' 'empty-name:=6c:92:bf:2f:aa:28=10'; do
    name="${case_%%:*}"
    reset; set -- --host "${case_#*:}"; eval "$PARSER"
    [ -n "$DIED" ] || fail "--host case '$name' was accepted"
done
reset; set -- --host 'a=6c:92:bf:2f:aa:28=10' --host 'a=6c:92:bf:2f:aa:29=11'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'given twice' || fail "duplicate hostname accepted"
reset; set -- --host 'a=6c:92:bf:2f:aa:28=10' --host 'b=6C:92:BF:2F:AA:28=11'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'given twice' || fail "duplicate client accepted"
reset; set -- --host 'a=6c:92:bf:2f:aa:28=10' --host 'b=6c:92:bf:2f:aa:29=010'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'given twice' || fail "duplicate HOSTID (10 vs 010) accepted"
reset; set -- --host 'Nas=6c:92:bf:2f:aa:28=10' --host 'nas=6c:92:bf:2f:aa:29=11'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'given twice' || fail "hostnames differing only in case accepted (DNS is case-insensitive)"
# a DUID-LLT/LL carries the MAC: the same machine under two keys
reset; set -- --host 'a=6c:92:bf:2f:aa:28=10' --host 'b=duid:00010001323a02a76c92bf2faa28=11'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'same client (MAC 6c:92:bf:2f:aa:28)' || fail "MAC line and DUID-LLT line for one client accepted: $DIED"
reset; set -- --host 'a=duid:000300016c92bf2faa28=10' --host 'b=6C:92:BF:2F:AA:28=11'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'same client' || fail "DUID-LL line and MAC line for one client accepted: $DIED"
reset; set -- --host 'a=duid:0004ecbcbfb80ef2996849bca6b0d0a6ffce=10' --host 'b=6c:92:bf:2f:aa:28=11'; eval "$PARSER"
[ -z "$DIED" ] || fail "a DUID-UUID line was treated as carrying a MAC: $DIED"
[ "$(mac_in_key duid 000300016c92bf2faa28%2b67)" = '6c:92:bf:2f:aa:28' ] || fail "mac_in_key does not ignore the IAID suffix"
[ -z "$(mac_in_key duid 00030001000000000000%2b67)" ] || fail "mac_in_key treated an all-zero MAC as an identity"
[ -z "$(mac_in_key duid 0004ecbcbfb80ef2996849bca6b0d0a6ffce)" ] || fail "mac_in_key invented a MAC for a UUID DUID"
# a BMC with one all-zero DUID on two ports: odhcpd keys host sections on DUID
# bytes and MACs only, so two duid-only lines differing by IAID collapse - refused
reset; set -- --host 'bmc1=duid:00030001000000000000%2b67=20' --host 'bmc2=duid:00030001000000000000%56ce=21'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'differ only by IAID' || fail "two duid-only lines differing by IAID accepted: $DIED"
# ... with the MACs they are two sections, and the all-zero MAC in the DUID does not merge them
reset; set -- --host 'bmc1=6c:92:bf:2f:aa:2a+duid:00030001000000000000%2b67=20' --host 'bmc2=6c:92:bf:2f:aa:2b+duid:00030001000000000000%56ce=21'; eval "$PARSER"
[ -z "$DIED" ] || fail "two BMC ports with their MACs rejected: $DIED"
# DUID length: odhcpd ignores clients under 10 or over 130 bytes
reset; set -- --host 'a=duid:0004ecbc=20'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'shorter than 10 bytes' || fail "a 4-byte DUID accepted"
reset; set -- --host "a=duid:$(printf 'ab%.0s' $(seq 131))=20"; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'longer than 130 bytes' || fail "a 131-byte DUID accepted"
reset; set -- --host "a=duid:$(printf 'ab%.0s' $(seq 130))=20"; eval "$PARSER"
[ -z "$DIED" ] || fail "a 130-byte DUID rejected: $DIED"
# odhcpd parses the IAID and the hostid numerically
reset; set -- --host 'a=duid:0004ecbcbfb80ef2996849bca6b0d0a6ffce%000a=20' --host 'b=duid:0004ecbcbfb80ef2996849bca6b0d0a6ffce%a=21'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'given twice' || fail "IAID %000a and %a accepted as different clients"
[ "$(norm_hostid 0x20)" = 20 ] || fail "norm_hostid does not strip a 0x prefix"
for case_ in 'leading-dash:-nas=6c:92:bf:2f:aa:28=10' 'trailing-dash:nas-=6c:92:bf:2f:aa:28=10' \
             "too-long:$(printf 'a%.0s' $(seq 64))=6c:92:bf:2f:aa:28=10"; do
    name="${case_%%:*}"
    reset; set -- --host "${case_#*:}"; eval "$PARSER"
    [ -n "$DIED" ] || fail "--host case '$name' was accepted"
done
reset; set -- --host "$(printf 'a%.0s' $(seq 63))=6c:92:bf:2f:aa:28=10"; eval "$PARSER"
[ -z "$DIED" ] || fail "a 63-character hostname rejected: $DIED"
echo 'PASS: --host rejects malformed and duplicate reservations'

# 3. --host needs the LAN stage; the DHCPv6 precondition is preflight's
reset; set -- --no-lan --host 'a=6c:92:bf:2f:aa:28=10'; eval "$PARSER"; eval "$POSTCHECK"
printf '%s' "$DIED" | grep -q 'no-lan' || fail "--host with --no-lan accepted"
reset; set -- --host 'a=6c:92:bf:2f:aa:28=10'; eval "$PARSER"; eval "$POSTCHECK"
[ -z "$DIED" ] || fail "--host alone must wait for preflight to check the LAN: $DIED"
# the same name as --dns-host and --host would leave two answers
reset; set -- --dns-host 'nas=300:1::5' --host 'NAS=6c:92:bf:2f:aa:28=10'; eval "$PARSER"; eval "$POSTCHECK"
printf '%s' "$DIED" | grep -q 'also given as --dns-host' || fail "--dns-host and --host for one name accepted"
echo 'PASS: --host post-parse checks'

# 4. address arithmetic
for case_ in '10:303:170f:3ab2:166e::10' '235:303:170f:3ab2:166e::235' 'abcd1234:303:170f:3ab2:166e::abcd:1234' \
             '1000000000000000:303:170f:3ab2:166e:1000::' '123456789abcdef:303:170f:3ab2:166e:123:4567:89ab:cdef'; do
    id="${case_%%:*}"; want="${case_#*:}"
    got="$(reserved_addr '303:170f:3ab2:166e::/64' "$id")"
    [ "$got" = "$want" ] || fail "reserved_addr $id: got $got, want $want"
done
[ "$(reserved_addr '303:170f::/64' 5)" = '303:170f::5' ] || fail "short prefix not zero-extended"
[ "$(reserved_addr '300:0:0:1::/64' 10)" = '300:0:0:1::10' ] || fail "inner zero hextets mishandled"
[ "$(norm_hostid 0AB0)" = ab0 ] || fail "norm_hostid did not lower-case and strip zeros"
[ "$(norm_hostid 000)" = 0 ] || fail "norm_hostid of zero is not 0"
[ "$(implicit_hostid 192.168.1.235)" = 235 ] || fail "implicit hostid for .235"
[ "$(implicit_hostid 192.168.1.5)" = 5 ] || fail "implicit hostid for .5"
echo 'PASS: reserved address, hostid normalisation and implicit suffix'

# 5. collision with existing config host sections, update in place, new section
UCI_LOG=''
uci_set()      { UCI_LOG="${UCI_LOG}set $1=$2
"; }
uci_del()      { UCI_LOG="${UCI_LOG}del $1
"; }
uci_add_list() { UCI_LOG="${UCI_LOG}add_list $1=$2
"; }
FIXTURE="dhcp.cfg01=host
dhcp.cfg01.name='desk'
dhcp.cfg01.mac='3c:e1:a1:41:52:d0'
dhcp.cfg01.ip='192.168.1.50'
dhcp.ygg_host_printer=host
dhcp.ygg_host_printer.name='printer'
dhcp.ygg_host_printer.mac='aa:bb:cc:dd:ee:20'
dhcp.ygg_host_printer.hostid='77'
dhcp.cfg02=host
dhcp.cfg02.name='zeonux'
dhcp.cfg02.mac='6c:92:bf:2f:aa:28'
dhcp.cfg02.ip='192.168.1.235'
dhcp.cfg02.hostid='10'
dhcp.cfg03=host
dhcp.cfg03.name='shared'
dhcp.cfg03.mac='aa:bb:cc:dd:ee:01' 'aa:bb:cc:dd:ee:02'
dhcp.cfg04=host
dhcp.cfg04.name='tagged'
dhcp.cfg04.mac='aa:bb:cc:dd:ee:03'
dhcp.cfg04.tag='iot'
dhcp.cfg06=host
dhcp.cfg06.name='byduid'
dhcp.cfg06.duid='00030001aabbccddee40'
dhcp.cfg06.hostid='40'
dhcp.lan=dhcp
dhcp.lan.dhcpv6='disabled'"
uci() {
    case "$1 $2" in
        'show dhcp') printf '%s\n' "$FIXTURE" ;;
        '-q get') case "$3" in dhcp.ygg_host_printer) echo host ;; dhcp.ygg_host_alias) echo domain ;; *) return 1 ;; esac ;;
        *) return 0 ;;
    esac
}
YGG_PREFIX='303:170f:3ab2:166e::/64'

lines="$(existing_hosts)"
[ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" = 6 ] || fail "existing_hosts did not list six sections: $lines"
printf '%s\n' "$lines" | grep -qxF 'dhcp.cfg02|10|192.168.1.235|6c:92:bf:2f:aa:28||' || fail "cfg02 line wrong: $lines"
printf '%s\n' "$lines" | grep -qF 'dhcp.cfg03||' | grep -q 'aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:02' \
    || printf '%s\n' "$lines" | grep -qF '|aa:bb:cc:dd:ee:01,aa:bb:cc:dd:ee:02|' || fail "multi-MAC list not joined: $lines"
printf '%s\n' "$lines" | grep -qF 'dhcp.cfg04|||aa:bb:cc:dd:ee:03|| tag' || fail "extra option not reported: $lines"

reset; UCI_LOG=''; HOSTS='cam mac aa:bb:cc:dd:ee:10 50'; apply_hosts
printf '%s' "$DIED" | grep -q 'already taken by cfg01 (implicit, from ip 192.168.1.50)' \
    || fail "collision with implicit ::50 not detected: $DIED"
reset; UCI_LOG=''; HOSTS='cam mac aa:bb:cc:dd:ee:10 10'; apply_hosts
printf '%s' "$DIED" | grep -q 'already taken by cfg02 (hostid 10)' || fail "collision with explicit hostid not detected: $DIED"
reset; UCI_LOG=''; HOSTS='zeonux mac 6c:92:bf:2f:aa:28 10'; apply_hosts
[ -z "$DIED" ] || fail "re-supplying an existing reservation died: $DIED"
printf '%s' "$UCI_LOG" | grep -qxF 'set dhcp.cfg02.hostid=10' || fail "existing section not updated in place: $UCI_LOG"
printf '%s' "$UCI_LOG" | grep -q 'ygg_host_' && fail "a second section was created for an existing MAC"
reset; UCI_LOG=''; HOSTS='cam mac aa:bb:cc:dd:ee:10 60'; apply_hosts
[ -z "$DIED" ] || fail "new reservation died: $DIED"
printf '%s' "$UCI_LOG" | grep -qxF 'set dhcp.ygg_host_cam=host' || fail "new section not created: $UCI_LOG"
printf '%s' "$UCI_LOG" | grep -qxF 'set dhcp.ygg_host_cam.mac=aa:bb:cc:dd:ee:10' || fail "MAC not written: $UCI_LOG"
printf '%s' "$UCI_LOG" | grep -qxF 'set dhcp.ygg_host_cam.hostid=60' || fail "hostid not written: $UCI_LOG"
printf '%s' "$INFOD" | grep -q 'cam -> 303:170f:3ab2:166e::60' || fail "reserved address not reported: $INFOD"
reset; UCI_LOG=''; HOSTS='x mac aa:bb:cc:dd:ee:01 70'; apply_hosts
printf '%s' "$DIED" | grep -q 'several MACs' || fail "shared multi-MAC section was edited: $DIED"
reset; UCI_LOG=''; HOSTS='x mac aa:bb:cc:dd:ee:03 70'; apply_hosts
printf '%s' "$DIED" | grep -q 'extra options (tag)' || fail "section with extra options was edited: $DIED"
# the derived section id is already taken by a different client
reset; UCI_LOG=''; HOSTS='printer mac aa:bb:cc:dd:ee:99 80'; apply_hosts
printf '%s' "$DIED" | grep -q 'ygg_host_printer already exists (host)' || fail "occupied section id was reused: $DIED"
printf '%s' "$UCI_LOG" | grep -q 'ygg_host_printer' && fail "occupied section was written to anyway: $UCI_LOG"
# the same client re-supplied under its own id updates in place, no collision
reset; UCI_LOG=''; HOSTS='printer mac aa:bb:cc:dd:ee:20 77'; apply_hosts
[ -z "$DIED" ] || fail "re-supplying the printer reservation died: $DIED"
printf '%s' "$UCI_LOG" | grep -qxF 'set dhcp.ygg_host_printer.hostid=77' || fail "printer not updated in place: $UCI_LOG"
# the derived id exists as a section of another type
reset; UCI_LOG=''; HOSTS='alias mac aa:bb:cc:dd:ee:98 81'; apply_hosts
printf '%s' "$DIED" | grep -q 'ygg_host_alias already exists (domain)' || fail "a non-host section with the derived id was converted: $DIED"
printf '%s' "$UCI_LOG" | grep -q 'ygg_host_alias' && fail "non-host section was written to: $UCI_LOG"
# a section reserved by a DUID-LL is the same client as a --host line by that MAC
reset; UCI_LOG=''; HOSTS='byduid mac aa:bb:cc:dd:ee:40 41'; apply_hosts
[ -z "$DIED" ] || fail "MAC line against an existing DUID-LL section died: $DIED"
printf '%s' "$UCI_LOG" | grep -qxF 'set dhcp.cfg06.hostid=41' || fail "existing DUID-LL section not updated by the MAC line: $UCI_LOG"
printf '%s' "$UCI_LOG" | grep -q 'ygg_host_byduid' && fail "a second section was created beside the DUID-LL one"
reset; UCI_LOG=''; HOSTS='other mac aa:bb:cc:dd:ee:40 40'; apply_hosts
[ -z "$DIED" ] || fail "re-supplying the DUID-LL client its own suffix by MAC died: $DIED"
# and the reverse: a DUID-LLT line against a section that holds only the MAC
reset; UCI_LOG=''; HOSTS='desk duid 00010001cafebabe3ce1a14152d0 51'; apply_hosts
[ -z "$DIED" ] || fail "DUID-LLT line against an existing MAC section died: $DIED"
printf '%s' "$UCI_LOG" | grep -qxF 'set dhcp.cfg01.hostid=51' || fail "existing MAC section not updated by the DUID-LLT line: $UCI_LOG"
printf '%s' "$UCI_LOG" | grep -qxF 'set dhcp.cfg01.duid=00010001cafebabe3ce1a14152d0' || fail "the DUID the line carries was not recorded: $UCI_LOG"
printf '%s' "$UCI_LOG" | grep -q 'set dhcp.cfg01.mac=' && fail "a duid-form line rewrote the MAC"
# a DUID gaining its %IAID on an existing section
uci() { case "$1 $2" in 'show dhcp') printf '%s\n' "$FIXTURE
dhcp.cfg07=host
dhcp.cfg07.name='lap'
dhcp.cfg07.mac='aa:bb:cc:dd:ee:60'
dhcp.cfg07.duid='0004ecbcbfb80ef2996849bca6b0d0a6ffce'
dhcp.cfg07.hostid='60'" ;; '-q get') return 1 ;; *) return 0 ;; esac; }
reset; UCI_LOG=''; HOSTS='lap mac+duid aa:bb:cc:dd:ee:60+0004ecbcbfb80ef2996849bca6b0d0a6ffce%206de1ca 60'; apply_hosts
[ -z "$DIED" ] || fail "adding an IAID to an existing reservation died: $DIED"
printf '%s' "$UCI_LOG" | grep -qxF 'set dhcp.cfg07.duid=0004ecbcbfb80ef2996849bca6b0d0a6ffce%206de1ca' || fail "the DUID did not gain its IAID: $UCI_LOG"
printf '%s' "$UCI_LOG" | grep -q 'set dhcp.cfg07.mac=' && fail "an unchanged MAC was rewritten"
# a zero-padded IAID in UCI is the same client as its canonical spelling
uci() { case "$1 $2" in 'show dhcp') printf '%s\n' "$FIXTURE
dhcp.cfg08=host
dhcp.cfg08.name='padded'
dhcp.cfg08.duid='0004ecbcbfb80ef2996849bca6b0d0a6ffce%000A'
dhcp.cfg08.hostid='70'" ;; '-q get') return 1 ;; *) return 0 ;; esac; }
reset; UCI_LOG=''; HOSTS='padded duid 0004ecbcbfb80ef2996849bca6b0d0a6ffce%a 70'; apply_hosts
[ -z "$DIED" ] || fail "canonical IAID against a zero-padded UCI value died: $DIED"
printf '%s' "$UCI_LOG" | grep -qxF 'set dhcp.cfg08.hostid=70' || fail "zero-padded IAID section not recognised: $UCI_LOG"
printf '%s' "$UCI_LOG" | grep -q 'set dhcp.cfg08.duid=' && fail "an equivalent DUID spelling was rewritten"
printf '%s' "$UCI_LOG" | grep -q 'ygg_host_padded' && fail "a second section was created beside the zero-padded one"
# two existing sections that both stand for one combined line: refused, not merged
uci() { case "$1 $2" in 'show dhcp') printf '%s\n' "$FIXTURE
dhcp.cfg09=host
dhcp.cfg09.duid='0004ecbcbfb80ef2996849bca6b0d0a6ffce%000a'
dhcp.cfg09.hostid='71'" ;; '-q get') return 1 ;; *) return 0 ;; esac; }
reset; UCI_LOG=''; HOSTS='desk mac+duid 3c:e1:a1:41:52:d0+0004ecbcbfb80ef2996849bca6b0d0a6ffce%a 72'; apply_hosts
printf '%s' "$DIED" | grep -q 'appears in 2 config host sections' || fail "identifiers split across two sections were not detected: $DIED"
uci() { case "$1 $2" in 'show dhcp') printf '%s\n' "$FIXTURE" ;; '-q get') case "$3" in dhcp.ygg_host_printer) echo host ;; dhcp.ygg_host_alias) echo domain ;; *) return 1 ;; esac ;; *) return 0 ;; esac; }
# the combined form: a new section gets both identifiers ...
reset; UCI_LOG=''; HOSTS='laptop mac+duid aa:bb:cc:dd:ee:50+0004ecbcbfb80ef2996849bca6b0d0a6ffce%a 52'; apply_hosts
[ -z "$DIED" ] || fail "combined form on a new client died: $DIED"
for want in 'set dhcp.ygg_host_laptop=host' 'set dhcp.ygg_host_laptop.mac=aa:bb:cc:dd:ee:50' 'set dhcp.ygg_host_laptop.duid=0004ecbcbfb80ef2996849bca6b0d0a6ffce%a' 'set dhcp.ygg_host_laptop.hostid=52'; do
    printf '%s' "$UCI_LOG" | grep -qxF "$want" || fail "combined form did not write '$want': $UCI_LOG"
done
# ... and an existing section matched by one identifier gains the other
reset; UCI_LOG=''; HOSTS='desk mac+duid 3c:e1:a1:41:52:d0+0004ecbcbfb80ef2996849bca6b0d0a6ffce%a 53'; apply_hosts
[ -z "$DIED" ] || fail "combined form against an existing MAC-only section died: $DIED"
printf '%s' "$UCI_LOG" | grep -qxF 'set dhcp.cfg01.duid=0004ecbcbfb80ef2996849bca6b0d0a6ffce%a' || fail "existing MAC section did not gain the DUID: $UCI_LOG"
printf '%s' "$UCI_LOG" | grep -q 'set dhcp.cfg01.mac=' && fail "existing MAC was rewritten"
reset; UCI_LOG=''; HOSTS='byduid mac+duid aa:bb:cc:dd:ee:40+00030001aabbccddee40 40'; apply_hosts
[ -z "$DIED" ] || fail "combined form against an existing DUID-only section died: $DIED"
printf '%s' "$UCI_LOG" | grep -qxF 'set dhcp.cfg06.mac=aa:bb:cc:dd:ee:40' || fail "existing DUID section did not gain the MAC: $UCI_LOG"
# two lines resolving to one existing section (MAC form and DUID-LLT form)
uci() { case "$1 $2" in 'show dhcp') printf '%s\n' "$FIXTURE
dhcp.cfg05=host
dhcp.cfg05.name='both'
dhcp.cfg05.mac='aa:bb:cc:dd:ee:30'
dhcp.cfg05.duid='00010001deadbeefaabbccddee30'" ;; '-q get') return 1 ;; *) return 0 ;; esac; }
reset; UCI_LOG=''; HOSTS='p mac aa:bb:cc:dd:ee:30 81
q duid 00010001deadbeefaabbccddee30 82'; apply_hosts
printf '%s' "$DIED" | grep -q 'already updated for another --host line' || fail "one section updated twice: $DIED"
uci() { case "$1 $2" in 'show dhcp') printf '%s\n' "$FIXTURE" ;; '-q get') return 1 ;; *) return 0 ;; esac; }
# implicit reservations are reported even without any --host
reset; INFOD=''; report_implicit_hosts
printf '%s' "$INFOD" | grep -q 'cfg01 (3c:e1:a1:41:52:d0, ip 192.168.1.50) implies suffix ::50' || fail "report_implicit_hosts silent: $INFOD"
printf '%s' "$INFOD" | grep -q 'cfg02' && fail "a section with an explicit hostid was reported as implicit"
echo 'PASS: reservation collisions, in-place update and protected sections'

# 5c. the firewall zone of the LAN network is resolved, not assumed
LAN='guests'
uci() { case "$1 $2" in 'show firewall') printf "%s\n" "firewall.cfg02dc81=zone" "firewall.cfg02dc81.name='lan'" "firewall.cfg02dc81.network='lan' 'guests'" "firewall.cfg03dc81=zone" "firewall.cfg03dc81.name='wan'" "firewall.cfg03dc81.network='wan' 'wan6'" ;; '-q get') case "$3" in firewall.cfg02dc81.name) echo lan ;; *) return 1 ;; esac ;; *) return 1 ;; esac; }
reset; [ "$(lan_zone)" = 'lan' ] || fail "zone of network 'guests' not resolved to 'lan': $(lan_zone)"
warn() { printf 'WARN:%s\n' "$*"; }
LAN='dmz'; reset; got="$(lan_zone)"
[ "${got##*
}" = 'dmz' ] || fail "unlisted network did not fall back to its own name: $got"
printf '%s' "$got" | grep -q 'WARN:no firewall zone lists' || fail "fallback not reported: $got"
warn()  { WARNED="${WARNED}${*}
"; }
LAN='lan'; unset -f uci
echo 'PASS: LAN zone resolution'

# 6. the UCI values the LAN stage writes (dry run: no commit, no services,
#    no assignment wait)
DRY_RUN=1; IFACE='ygg0'; LAN='lan'; YGG_CLASS='ygg0'; YGG_PREFIX='303:170f:3ab2:166e::/64'
uci() { case "$1 $2" in 'show dhcp') printf '%s\n' "$FIXTURE" ;; '-q get') printf '%s\n' "" ; return 0 ;; *) return 0 ;; esac; }
wrote() { printf '%s' "$UCI_LOG" | grep -qxF "$1"; }
# a stock router: only ra / ra_default; everything else untouched
reset; UCI_LOG=''; CUR_IP6ASSIGN=60; CUR_ULA='fd75:921a:ca44::/48'; CUR_DHCPV6=server; CUR_RA_SLAAC=1; CUR_RA_FLAGS='managed-config other-config '; stage_lan
[ -z "$DIED" ] || fail "overlay stage on stock died: $DIED"
for want in 'set dhcp.lan.ra=server' 'set dhcp.lan.ra_default=2'; do
    wrote "$want" || fail "overlay did not write '$want':
$UCI_LOG"
done
for forbidden in 'network.lan.ip6assign' 'ip6class' 'ula_prefix' 'dhcp.lan.dhcpv6' 'ra_slaac' 'ra_flags' 'ra_preference'; do
    printf '%s' "$UCI_LOG" | grep -q "$forbidden" && fail "overlay on a stock router touched $forbidden:
$UCI_LOG"
done
[ "$(printf '%s' "$UCI_LOG" | grep -c .)" = 2 ] || fail "overlay on stock must write exactly two values:
$UCI_LOG"
# ip6assign only when unset
reset; UCI_LOG=''; CUR_IP6ASSIGN=''; stage_lan
wrote 'set network.lan.ip6assign=64' || fail "unset ip6assign not defaulted to 64"
# an ip6class list is kept and made to admit the class; one that admits it is untouched
reset; UCI_LOG=''; CUR_IP6ASSIGN=64; CUR_IP6CLASS='wan6 local'; stage_lan
wrote 'add_list network.lan.ip6class=ygg0' || fail "custom ip6class did not gain the class:
$UCI_LOG"
printf '%s' "$UCI_LOG" | grep -q 'del network.lan.ip6class' && fail "custom ip6class was deleted"
reset; UCI_LOG=''; CUR_IP6ASSIGN=64; CUR_IP6CLASS='local ygg0'; stage_lan
printf '%s' "$UCI_LOG" | grep -q 'ip6class' && fail "an admitting ip6class was rewritten:
$UCI_LOG"
# reservations are applied (the section-5 uci stub: fixture + missing sections)
uci() { case "$1 $2" in 'show dhcp') printf '%s\n' "$FIXTURE" ;; '-q get') return 1 ;; *) return 0 ;; esac; }
reset; UCI_LOG=''; CUR_IP6ASSIGN=60; HOSTS='cam mac aa:bb:cc:dd:ee:70 70'; stage_lan
[ -z "$DIED" ] || fail "LAN stage with a reservation died: $DIED"
wrote 'set dhcp.ygg_host_cam.hostid=70' || fail "reservation not applied:
$UCI_LOG"
uci() { case "$1 $2" in 'show dhcp') printf '%s\n' "$FIXTURE" ;; '-q get') printf '%s\n' "" ; return 0 ;; *) return 0 ;; esac; }
echo 'PASS: the LAN stage writes exactly the overlay values'

# 7. the LAN-to-Yggdrasil rule follows --no-lan-forward; the zone is unchanged
lan_zone() { echo lan; }
reset; UCI_LOG=''; stage_firewall
[ -z "$DIED" ] || fail "firewall stage died: $DIED"
for want in 'set firewall.ygg_lan_out=rule' 'set firewall.ygg_lan_out.src=lan' 'set firewall.ygg_lan_out.dest=ygg' \
            'set firewall.ygg_lan_out.family=ipv6' 'set firewall.ygg_lan_out.dest_ip=200::/7' 'set firewall.ygg_lan_out.target=ACCEPT' \
            'set firewall.ygg.forward=DROP' 'set firewall.ygg.input=REJECT' 'del firewall.ygg.masq6'; do
    wrote "$want" || fail "firewall stage did not write '$want':
$UCI_LOG"
done
printf '%s' "$UCI_LOG" | grep -q '=forwarding' && fail "a zone-wide forwarding was written instead of a rule"
reset; UCI_LOG=''; DO_LAN_FORWARD=0; stage_firewall
wrote 'del firewall.ygg_lan_out' || fail "--no-lan-forward did not remove the rule:
$UCI_LOG"
printf '%s' "$UCI_LOG" | grep -q 'set firewall.ygg_lan_out' && fail "--no-lan-forward still wrote the rule"
echo 'PASS: LAN-to-Yggdrasil rule'

echo 'deploy-lan-overlay: all checks passed'
