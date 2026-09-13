#!/bin/sh
# shellcheck disable=SC2034,SC2317,SC2329
# The deployer's option loop and helpers are extracted with sed/awk and
# evaluated here, which hides their references from ShellCheck.
#
# Deployer 1.8.0 added --config FILE: one settings file whose sections stand
# for the command-line options. This checks that every section lands in the
# variable its option would set, that the file goes through the same
# validation, and that the key from the file takes its place in the precedence.

set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/deploy/deploy-openwrt-yggdrasil.sh"
TMP="$(mktemp -d /tmp/ygg-config-test.XXXXXX)"
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
for f in add_peer add_trusted add_dns_host status_valid_version read_config validate_private_key load_supplied_key; do
    body="$(extract_function "$f")"
    [ -n "$body" ] || { echo "FAIL: function $f not found in deployer" >&2; exit 1; }
    eval "$body"
done
PARSER="$(sed -n '/^while \[ \$# -gt 0 \]; do$/,/^done$/p' "$SCRIPT")"

DIED=''; WARNED=''
die()   { DIED="$*"; }
warn()  { WARNED="${WARNED}${*}
"; }
ok()    { :; }
usage() { :; }
SECRET='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. every section lands where its option would
umask 077
cat > "$TMP/full.conf" <<CONF
# full settings file
[ peers ]
tls://a.example:443      # inline comment
  wss://b.example/ygg

[trusted]
200::1
201:2::3
[private-key]
$SECRET
[iface]
ygg9
[lan]
guest
[dns-domain]
lan.example
[dns-router]
gw
[dns-hosts]
nas=200::10
nas=200::11
[status-version]
v5.2
[status-pkg]
/root/yggdrasil-status.tar.gz
[flags]
no-jumper
no-dns
no-status
CONF
set -- --config "$TMP/full.conf"
eval "$PARSER"
[ -z "$DIED" ] || fail "valid config rejected: $DIED"
[ "$(printf '%s\n' "$PEERS" | wc -l | tr -d ' ')" = 2 ] || fail "[peers] did not yield two peers"
printf '%s\n' "$PEERS" | grep -qxF 'wss://b.example/ygg' || fail "indented peer line was not trimmed"
[ "$(printf '%s\n' "$TRUSTED" | wc -l | tr -d ' ')" = 2 ] || fail "[trusted] did not yield two addresses"
{ [ "$IFACE" = ygg9 ] && [ "$LAN" = guest ]; } || fail "[iface]/[lan] not applied"
{ [ "$DNS_DOMAIN" = lan.example ] && [ "$DNS_ROUTER" = gw ]; } || fail "[dns-domain]/[dns-router] not applied"
[ "$(printf '%s\n' "$DNS_HOSTS" | wc -l | tr -d ' ')" = 2 ] || fail "[dns-hosts] did not yield two records"
{ [ "$STATUS_VERSION" = v5.2 ] && [ "$STATUS_PKG" = /root/yggdrasil-status.tar.gz ]; } || fail "[status-*] not applied"
{ [ "$DO_JUMPER" = 0 ] && [ "$DO_DNS" = 0 ] && [ "$DO_STATUS" = 0 ]; } || fail "[flags] not applied"
{ [ "$DO_LAN" = 1 ] && [ "$DO_FIREWALL" = 1 ] && [ "$DO_MULTICAST" = 1 ]; } || fail "[flags] touched a switch it did not name"
[ "$CONFIG_KEY" = "$SECRET" ] || fail "[private-key] not captured"
[ -z "$WARNED" ] || fail "a mode-600 config file drew a warning: $WARNED"
echo 'PASS: every settings-file section lands in its option variable'

# 2. later command-line options add to lists and override single values
set -- --config "$TMP/full.conf" --iface ygg0 --peer tls://c.example:1
PEERS=''; TRUSTED=''; DNS_HOSTS=''; CONFIG_KEY=''; DIED=''
eval "$PARSER"
[ -z "$DIED" ] || fail "config plus options rejected: $DIED"
[ "$IFACE" = ygg0 ] || fail "a later --iface did not override [iface]"
[ "$(printf '%s\n' "$PEERS" | wc -l | tr -d ' ')" = 3 ] || fail "a later --peer did not add to [peers]"
echo 'PASS: options after --config add to lists and override single values'

# 3. the file is validated like the command line
for case_ in 'unknown-section:[dns]
x' 'bad-peer:[peers]
http://x' 'bad-flag:[flags]
no-such-flag' 'no-section:tls://x:1' 'bad-version:[status-version]
5.2' 'two-keys:[private-key]
'"$SECRET"'
'"$SECRET"; do
    name="${case_%%:*}"
    printf '%s\n' "${case_#*:}" > "$TMP/$name.conf"
    PEERS=''; CONFIG_KEY=''; DIED=''
    set -- --config "$TMP/$name.conf"
    eval "$PARSER"
    [ -n "$DIED" ] || fail "config case '$name' was accepted"
done
# die is stubbed and does not exit here, so the loop's redirection fails
# afterwards; the subshell keeps that from ending the test.
( set +e; DIED=''; set -- --config "$TMP/does-not-exist.conf"; eval "$PARSER" 2>/dev/null; [ -n "$DIED" ] ) \
    || fail "a missing config file was accepted"
echo 'PASS: settings-file values go through the same validation as options'

# 4. a world-readable file holding the key warns; the key takes its place
#    after a key file and before the environment, and never reaches argv
chmod 644 "$TMP/full.conf"
PEERS=''; TRUSTED=''; DNS_HOSTS=''; CONFIG_KEY=''; DIED=''; WARNED=''
set -- --config "$TMP/full.conf"
eval "$PARSER"
printf '%s' "$WARNED" | grep -q 'readable beyond its owner' || fail "mode 644 config with a key did not warn"
chmod 600 "$TMP/full.conf"

PRIVATE_KEY_FILE=''; SUPPLIED_KEY=''; DIED=''
YGG_PRIVATE_KEY="$(printf 'ff%.0s' $(seq 64))"; export YGG_PRIVATE_KEY
load_supplied_key
[ -z "$DIED" ] || fail "config key rejected by load_supplied_key: $DIED"
[ "$SUPPLIED_KEY" = "$SECRET" ] || fail "[private-key] did not take precedence over YGG_PRIVATE_KEY"
[ -z "${YGG_PRIVATE_KEY-}" ] || fail "environment key was left exported"

printf 'ee%.0s' $(seq 64) > "$TMP/key"; chmod 600 "$TMP/key"
PRIVATE_KEY_FILE="$TMP/key"; SUPPLIED_KEY=''
load_supplied_key
[ "$SUPPLIED_KEY" = "$(cat "$TMP/key")" ] || fail "--private-key-file did not take precedence over [private-key]"

if grep -qE -- '--private-key\)' "$SCRIPT"; then
    fail "a --private-key option taking the key as a value exists"
fi
echo 'PASS: config key warns on a wide mode, sits between key file and environment, never an argument'
