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
for f in add_peer add_trusted add_dns_host norm_hostid add_host status_valid_version read_config \
         reserved_addr implicit_hostid existing_hosts apply_hosts stage_lan; do
    body="$(extract_function "$f")"
    [ -n "$body" ] || { echo "FAIL: function $f not found in deployer" >&2; exit 1; }
    eval "$body"
done
PARSER="$(sed -n '/^while \[ \$# -gt 0 \]; do$/,/^done$/p' "$SCRIPT")"
POSTCHECK="$(sed -n '/^# A reservation only means something/,/^fi$/p' "$SCRIPT")"
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
reset() { DIED=''; WARNED=''; INFOD=''; HOSTS=''; LAN_MODE='slaac'; DO_LAN=1; DO_DNS=1; }

# 1. mode precedence: last switch wins, file flags count like switches
reset; set --; eval "$PARSER"
[ "$LAN_MODE" = slaac ] || fail "default LAN mode is not slaac"
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
echo 'PASS: --host rejects malformed and duplicate reservations'

# 3. --host needs managed mode and the LAN stage
reset; set -- --host 'a=6c:92:bf:2f:aa:28=10'; eval "$PARSER"; eval "$POSTCHECK"
printf '%s' "$DIED" | grep -q 'needs --dhcpv6' || fail "--host without --dhcpv6 accepted"
reset; set -- --dhcpv6 --no-lan --host 'a=6c:92:bf:2f:aa:28=10'; eval "$PARSER"; eval "$POSTCHECK"
printf '%s' "$DIED" | grep -q 'no-lan' || fail "--host with --no-lan accepted"
reset; set -- --dhcpv6 --host 'a=6c:92:bf:2f:aa:28=10'; eval "$PARSER"; eval "$POSTCHECK"
[ -z "$DIED" ] || fail "--dhcpv6 --host rejected: $DIED"
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
dhcp.lan=dhcp
dhcp.lan.dhcpv6='disabled'"
uci() {
    case "$1 $2" in
        'show dhcp') printf '%s\n' "$FIXTURE" ;;
        '-q get') return 1 ;;
        *) return 0 ;;
    esac
}
YGG_PREFIX='303:170f:3ab2:166e::/64'

lines="$(existing_hosts)"
[ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" = 4 ] || fail "existing_hosts did not list four sections: $lines"
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
printf '%s' "$INFOD" | grep -q 'cfg01 (3c:e1:a1:41:52:d0, ip 192.168.1.50) implies suffix ::50' \
    || fail "implicit reservation of cfg01 not reported: $INFOD"
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
