#!/bin/sh
# shellcheck disable=SC2034,SC2317,SC2329
# The deployer's option loop and helpers are extracted with sed/awk and
# evaluated here, which hides their references from ShellCheck.
#
# Deployer 1.9.0 added the LAN addressing mode (--dhcpv6 / --slaac) and DHCPv6
# reservations (--host). This checks option precedence, the reservation
# grammar, the address arithmetic, the collision check against existing
# config host sections, and the UCI values each mode writes.

set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/deploy/deploy-openwrt-yggdrasil.sh"
TMP="$(mktemp -d /tmp/ygg-lanmode-test.XXXXXX)"
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
for f in add_peer add_trusted add_dns_host lower_str is_mac norm_duid duid_in_key mac_in_key norm_hostid add_host status_valid_version read_config \
         resolve_lan_mode reserved_addr implicit_hostid existing_hosts section_is_client report_implicit_hosts apply_hosts stage_lan; do
    body="$(extract_function "$f")"
    [ -n "$body" ] || { echo "FAIL: function $f not found in deployer" >&2; exit 1; }
    eval "$body"
done
PARSER="$(sed -n '/^while \[ \$# -gt 0 \]; do$/,/^done$/p' "$SCRIPT")"
POSTCHECK="$(sed -n '/^# A reservation only means something/,/^# Ask for the Yggdrasil/p' "$SCRIPT" | sed '$d')"
[ -n "$POSTCHECK" ] || { echo 'FAIL: --host post-parse check not found' >&2; exit 1; }

DIED=''; WARNED=''; INFOD=''
die()   { DIED="${DIED}${*}
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
reset() { DIED=''; WARNED=''; INFOD=''; HOSTS=''; DNS_HOSTS=''; LAN_MODE='keep'; DO_LAN=1; DO_DNS=1; }

# 1. mode precedence: last switch wins, file flags count like switches; without
#    a switch the router keeps the mode it runs, a fresh router gets SLAAC
reset; set --; eval "$PARSER"
[ "$LAN_MODE" = keep ] || fail "default LAN mode is not keep"
LAN='lan'
uci() { case "$1 $2 $3" in '-q get dhcp.lan.dhcpv6') echo "$CUR_DHCPV6" ;; *) return 1 ;; esac; }
CUR_DHCPV6='server'; reset; resolve_lan_mode
[ "$LAN_MODE" = dhcpv6 ] || fail "a managed router was not kept managed on a plain rerun"
CUR_DHCPV6='disabled'; reset; resolve_lan_mode
[ "$LAN_MODE" = slaac ] || fail "a SLAAC router was not kept on SLAAC"
CUR_DHCPV6=''; reset; resolve_lan_mode
[ "$LAN_MODE" = slaac ] || fail "a fresh router did not default to SLAAC"
CUR_DHCPV6='disabled'; reset; HOSTS='a mac 6c:92:bf:2f:aa:28 10'; resolve_lan_mode
printf '%s' "$DIED" | grep -q 'needs --dhcpv6' || fail "--host on a kept SLAAC router accepted"
CUR_DHCPV6='server'; reset; HOSTS='a mac 6c:92:bf:2f:aa:28 10'; resolve_lan_mode
[ -z "$DIED" ] || fail "--host on a kept managed router rejected: $DIED"
CUR_DHCPV6='server'; reset; LAN_MODE='slaac'; resolve_lan_mode
[ "$LAN_MODE" = slaac ] || fail "an explicit --slaac did not override the current managed mode"
unset -f uci
reset; set -- --dhcpv6; eval "$PARSER"
[ "$LAN_MODE" = dhcpv6 ] || fail "--dhcpv6 not applied"
reset; set -- --dhcpv6 --slaac; eval "$PARSER"
[ "$LAN_MODE" = slaac ] || fail "--slaac after --dhcpv6 did not win"
reset; set -- --slaac --dhcpv6; eval "$PARSER"
[ "$LAN_MODE" = dhcpv6 ] || fail "--dhcpv6 after --slaac did not win"
umask 077
printf '[flags]\ndhcpv6\n[hosts]\nnas=6c:92:bf:2f:aa:28=10\n' > "$TMP/managed.conf"
reset; set -- --config "$TMP/managed.conf"; eval "$PARSER"
[ -z "$DIED" ] || fail "managed settings file rejected: $DIED"
[ "$LAN_MODE" = dhcpv6 ] || fail "[flags] dhcpv6 not applied"
[ "$HOSTS" = 'nas mac 6c:92:bf:2f:aa:28 10' ] || fail "[hosts] line not applied: '$HOSTS'"
reset; set -- --config "$TMP/managed.conf" --slaac; eval "$PARSER"
[ "$LAN_MODE" = slaac ] || fail "--slaac after a managed settings file did not win"
echo 'PASS: LAN mode precedence'

# 2. reservation grammar
reset; set -- --dhcpv6 \
    --host 'Nas-1=6C:92:BF:2F:AA:28=010' \
    --host 'bmc=duid:00030001000000000000%2B67=20' \
    --host 'cam=duid:000100012F3A02A76c92bf2faa29=ABCD1234'
eval "$PARSER"
[ -z "$DIED" ] || fail "valid --host lines rejected: $DIED"
printf '%s\n' "$HOSTS" | grep -qxF 'Nas-1 mac 6c:92:bf:2f:aa:28 10' || fail "MAC/hostid not normalised: $HOSTS"
printf '%s\n' "$HOSTS" | grep -qxF 'bmc duid 00030001000000000000%2b67 20' || fail "duid%IAID form not kept: $HOSTS"
printf '%s\n' "$HOSTS" | grep -qxF 'cam duid 000100012f3a02a76c92bf2faa29 abcd1234' || fail "duid form not normalised: $HOSTS"
# MAC and DUID together, for a client whose DUID carries no MAC
reset; set -- --dhcpv6 --host 'Laptop=3C:E1:A1:41:52:D0+duid:0004ECBCBFB80EF2996849BCA6B0D0A6FFCE%0000A=20'; eval "$PARSER"
[ -z "$DIED" ] || fail "MAC+duid form rejected: $DIED"
[ "$HOSTS" = 'Laptop mac+duid 3c:e1:a1:41:52:d0+0004ecbcbfb80ef2996849bca6b0d0a6ffce%a 20' ] || fail "MAC+duid form not normalised: $HOSTS"
[ "$(mac_in_key mac+duid '3c:e1:a1:41:52:d0+0004ecbc%a')" = '3c:e1:a1:41:52:d0' ] || fail "mac_in_key on the combined form"
[ "$(duid_in_key mac+duid '3c:e1:a1:41:52:d0+0004ecbc%a')" = '0004ecbc%a' ] || fail "duid_in_key on the combined form"
[ -z "$(duid_in_key mac '3c:e1:a1:41:52:d0')" ] || fail "duid_in_key invented a DUID for a MAC"
reset; set -- --dhcpv6 --host 'a=3c:e1:a1:41:52+duid:0004ecbc=20'; eval "$PARSER"
printf '%s' "$DIED" | grep -q "before '+duid:' is not a MAC" || fail "bad MAC before +duid accepted"
reset; set -- --dhcpv6 --host 'a=3c:e1:a1:41:52:d0+duid:0004ecbc=20' --host 'b=duid:0004ECBC=21'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'same client (DUID 0004ecbc)' || fail "the same DUID under two forms accepted: $DIED"
reset; set -- --dhcpv6 --host 'a=3c:e1:a1:41:52:d0+duid:0004ecbc=20' --host 'b=3c:e1:a1:41:52:d0=21'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'same client (MAC 3c:e1:a1:41:52:d0)' || fail "the same MAC under two forms accepted: $DIED"
echo 'PASS: --host accepts MAC, DUID and DUID%IAID forms and normalises them'

for case_ in 'no-hostid:a=6c:92:bf:2f:aa:28' 'bad-mac:a=6c:92:bf:2f:aa=10' 'short-mac:a=6c:92:bf=10' \
             'zero:a=6c:92:bf:2f:aa:28=0' 'zero-padded:a=6c:92:bf:2f:aa:28=000' 'one:a=6c:92:bf:2f:aa:28=1' \
             'too-long:a=6c:92:bf:2f:aa:28=12345678901234567' 'not-hex:a=6c:92:bf:2f:aa:28=10g' \
             'dotted-name:a.b=6c:92:bf:2f:aa:28=10' 'bad-name:a_b=6c:92:bf:2f:aa:28=10' \
             'empty-duid:a=duid:=10' 'odd-duid:a=duid:abc=10' 'bad-iaid:a=duid:abcd%zz=10' \
             'long-iaid:a=duid:abcd%123456789=10' 'empty-name:=6c:92:bf:2f:aa:28=10'; do
    name="${case_%%:*}"
    reset; set -- --dhcpv6 --host "${case_#*:}"; eval "$PARSER"
    [ -n "$DIED" ] || fail "--host case '$name' was accepted"
done
reset; set -- --dhcpv6 --host 'a=6c:92:bf:2f:aa:28=10' --host 'a=6c:92:bf:2f:aa:29=11'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'given twice' || fail "duplicate hostname accepted"
reset; set -- --dhcpv6 --host 'a=6c:92:bf:2f:aa:28=10' --host 'b=6C:92:BF:2F:AA:28=11'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'given twice' || fail "duplicate client accepted"
reset; set -- --dhcpv6 --host 'a=6c:92:bf:2f:aa:28=10' --host 'b=6c:92:bf:2f:aa:29=010'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'given twice' || fail "duplicate HOSTID (10 vs 010) accepted"
reset; set -- --dhcpv6 --host 'Nas=6c:92:bf:2f:aa:28=10' --host 'nas=6c:92:bf:2f:aa:29=11'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'given twice' || fail "hostnames differing only in case accepted (DNS is case-insensitive)"
# a DUID-LLT/LL carries the MAC: the same machine under two keys
reset; set -- --dhcpv6 --host 'a=6c:92:bf:2f:aa:28=10' --host 'b=duid:00010001323a02a76c92bf2faa28=11'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'same client (MAC 6c:92:bf:2f:aa:28)' || fail "MAC line and DUID-LLT line for one client accepted: $DIED"
reset; set -- --dhcpv6 --host 'a=duid:000300016c92bf2faa28=10' --host 'b=6C:92:BF:2F:AA:28=11'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'same client' || fail "DUID-LL line and MAC line for one client accepted: $DIED"
reset; set -- --dhcpv6 --host 'a=duid:0004ecbcbfb80ef2996849bca6b0d0a6ffce=10' --host 'b=6c:92:bf:2f:aa:28=11'; eval "$PARSER"
[ -z "$DIED" ] || fail "a DUID-UUID line was treated as carrying a MAC: $DIED"
[ "$(mac_in_key duid 000300016c92bf2faa28%2b67)" = '6c:92:bf:2f:aa:28' ] || fail "mac_in_key does not ignore the IAID suffix"
[ -z "$(mac_in_key duid 00030001000000000000%2b67)" ] || fail "mac_in_key treated an all-zero MAC as an identity"
[ -z "$(mac_in_key duid 0004ecbcbfb80ef2996849bca6b0d0a6ffce)" ] || fail "mac_in_key invented a MAC for a UUID DUID"
# a BMC with one all-zero DUID on two ports: distinct IAIDs are distinct clients
reset; set -- --dhcpv6 --host 'bmc1=duid:00030001000000000000%2b67=20' --host 'bmc2=duid:00030001000000000000%56ce=21'; eval "$PARSER"
[ -z "$DIED" ] || fail "two IAIDs of a zero-MAC DUID rejected as one client: $DIED"
# odhcpd parses the IAID and the hostid numerically
reset; set -- --dhcpv6 --host 'a=duid:0004abcd%000a=20' --host 'b=duid:0004abcd%a=21'; eval "$PARSER"
printf '%s' "$DIED" | grep -q 'given twice' || fail "IAID %000a and %a accepted as different clients"
[ "$(norm_hostid 0x20)" = 20 ] || fail "norm_hostid does not strip a 0x prefix"
for case_ in 'leading-dash:-nas=6c:92:bf:2f:aa:28=10' 'trailing-dash:nas-=6c:92:bf:2f:aa:28=10' \
             "too-long:$(printf 'a%.0s' $(seq 64))=6c:92:bf:2f:aa:28=10"; do
    name="${case_%%:*}"
    reset; set -- --dhcpv6 --host "${case_#*:}"; eval "$PARSER"
    [ -n "$DIED" ] || fail "--host case '$name' was accepted"
done
reset; set -- --dhcpv6 --host "$(printf 'a%.0s' $(seq 63))=6c:92:bf:2f:aa:28=10"; eval "$PARSER"
[ -z "$DIED" ] || fail "a 63-character hostname rejected: $DIED"
echo 'PASS: --host rejects malformed and duplicate reservations'

# 3. --host needs managed mode and the LAN stage
reset; set -- --slaac --host 'a=6c:92:bf:2f:aa:28=10'; eval "$PARSER"; eval "$POSTCHECK"
printf '%s' "$DIED" | grep -q 'needs --dhcpv6' || fail "--host with --slaac accepted"
reset; set -- --dhcpv6 --no-lan --host 'a=6c:92:bf:2f:aa:28=10'; eval "$PARSER"; eval "$POSTCHECK"
printf '%s' "$DIED" | grep -q 'no-lan' || fail "--host with --no-lan accepted"
reset; set -- --dhcpv6 --host 'a=6c:92:bf:2f:aa:28=10'; eval "$PARSER"; eval "$POSTCHECK"
[ -z "$DIED" ] || fail "--dhcpv6 --host rejected: $DIED"
reset; set -- --host 'a=6c:92:bf:2f:aa:28=10'; eval "$PARSER"; eval "$POSTCHECK"
[ -z "$DIED" ] || fail "--host without a mode switch must wait for preflight to settle the mode: $DIED"
# the same name as --dns-host and --host would leave two answers
reset; set -- --dhcpv6 --dns-host 'nas=300:1::5' --host 'NAS=6c:92:bf:2f:aa:28=10'; eval "$PARSER"; eval "$POSTCHECK"
printf '%s' "$DIED" | grep -q 'also given as --dns-host' || fail "--dns-host and --host for one name accepted"
echo 'PASS: --host is refused outside managed mode'

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
dhcp.cfg07.duid='0004ecbc'
dhcp.cfg07.hostid='60'" ;; '-q get') return 1 ;; *) return 0 ;; esac; }
reset; UCI_LOG=''; HOSTS='lap mac+duid aa:bb:cc:dd:ee:60+0004ecbc%206de1ca 60'; apply_hosts
[ -z "$DIED" ] || fail "adding an IAID to an existing reservation died: $DIED"
printf '%s' "$UCI_LOG" | grep -qxF 'set dhcp.cfg07.duid=0004ecbc%206de1ca' || fail "the DUID did not gain its IAID: $UCI_LOG"
printf '%s' "$UCI_LOG" | grep -q 'set dhcp.cfg07.mac=' && fail "an unchanged MAC was rewritten"
uci() { case "$1 $2" in 'show dhcp') printf '%s\n' "$FIXTURE" ;; '-q get') case "$3" in dhcp.ygg_host_printer) echo host ;; dhcp.ygg_host_alias) echo domain ;; *) return 1 ;; esac ;; *) return 0 ;; esac; }
# the combined form: a new section gets both identifiers ...
reset; UCI_LOG=''; HOSTS='laptop mac+duid aa:bb:cc:dd:ee:50+0004ecbc%a 52'; apply_hosts
[ -z "$DIED" ] || fail "combined form on a new client died: $DIED"
for want in 'set dhcp.ygg_host_laptop=host' 'set dhcp.ygg_host_laptop.mac=aa:bb:cc:dd:ee:50' 'set dhcp.ygg_host_laptop.duid=0004ecbc%a' 'set dhcp.ygg_host_laptop.hostid=52'; do
    printf '%s' "$UCI_LOG" | grep -qxF "$want" || fail "combined form did not write '$want': $UCI_LOG"
done
# ... and an existing section matched by one identifier gains the other
reset; UCI_LOG=''; HOSTS='desk mac+duid 3c:e1:a1:41:52:d0+0004ecbc%a 53'; apply_hosts
[ -z "$DIED" ] || fail "combined form against an existing MAC-only section died: $DIED"
printf '%s' "$UCI_LOG" | grep -qxF 'set dhcp.cfg01.duid=0004ecbc%a' || fail "existing MAC section did not gain the DUID: $UCI_LOG"
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

# 6. the UCI values each mode writes (dry run: no commit, no services)
DRY_RUN=1; IFACE='ygg0'; LAN='lan'; YGG_CLASS='ygg0'
uci() { case "$1 $2" in 'show dhcp') printf '%s\n' "$FIXTURE" ;; '-q get') printf '%s\n' "" ; return 0 ;; *) return 0 ;; esac; }
reset; UCI_LOG=''; LAN_MODE='slaac'; stage_lan
[ -z "$DIED" ] || fail "slaac stage died: $DIED"
for want in 'set dhcp.lan.dhcpv6=disabled' 'set dhcp.lan.ra_slaac=1' 'del dhcp.lan.ra_flags' 'add_list dhcp.lan.ra_flags=none' \
            'set dhcp.lan.ra=server' 'set dhcp.lan.ra_default=2' 'set dhcp.lan.ra_preference=medium' \
            'set network.lan.ip6assign=64' 'add_list network.lan.ip6class=ygg0' 'del network.globals.ula_prefix'; do
    printf '%s' "$UCI_LOG" | grep -qxF "$want" || fail "slaac mode did not write '$want':
$UCI_LOG"
done
printf '%s' "$UCI_LOG" | grep -q 'managed-config' && fail "slaac mode wrote managed-config"
reset; UCI_LOG=''; LAN_MODE='dhcpv6'; stage_lan
[ -z "$DIED" ] || fail "managed stage died: $DIED"
for want in 'set dhcp.lan.dhcpv6=server' 'set dhcp.lan.ra_slaac=0' 'del dhcp.lan.ra_flags' \
            'add_list dhcp.lan.ra_flags=managed-config' 'add_list dhcp.lan.ra_flags=other-config' 'set dhcp.lan.ra=server'; do
    printf '%s' "$UCI_LOG" | grep -qxF "$want" || fail "managed mode did not write '$want':
$UCI_LOG"
done
printf '%s' "$UCI_LOG" | grep -q 'ra_flags=none' && fail "managed mode wrote ra_flags=none"
[ "$(printf '%s' "$UCI_LOG" | grep -c 'add_list dhcp.lan.ra_flags=')" = 2 ] || fail "ra_flags must be exactly two list entries"
# operator settings that would defeat the mode are refused, not overridden
uci() { case "$1 $2" in '-q get') case "$3" in *dhcpv6_na) echo 0 ;; *) echo '' ;; esac ;; 'show dhcp') printf '%s\n' "$FIXTURE" ;; *) return 0 ;; esac; }
reset; UCI_LOG=''; LAN_MODE='dhcpv6'; stage_lan
printf '%s' "$DIED" | grep -q 'dhcpv6_na=0' || fail "dhcpv6_na=0 was not refused"
uci() { case "$1 $2" in '-q get') case "$3" in *ra_offlink) echo 1 ;; *) echo '' ;; esac ;; 'show dhcp') printf '%s\n' "$FIXTURE" ;; *) return 0 ;; esac; }
reset; UCI_LOG=''; LAN_MODE='dhcpv6'; stage_lan
printf '%s' "$DIED" | grep -q 'ra_offlink=1' || fail "ra_offlink=1 was not refused"
reset; UCI_LOG=''; LAN_MODE='slaac'; stage_lan
[ -z "$DIED" ] || fail "slaac mode must not care about dhcpv6_na/ra_offlink: $DIED"
echo 'PASS: each LAN mode writes exactly its UCI values'

echo 'deploy-lan-mode: all checks passed'
