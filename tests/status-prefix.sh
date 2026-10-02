#!/bin/sh
# shellcheck disable=SC2034,SC2317,SC2329
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="$ROOT/source/yggdrasil-status/root/usr/libexec/rpcd/luci.yggdrasil-status"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
eq() { [ "$1" = "$2" ] || fail "expected [$1], got [$2]"; }
load() { eval "$(awk -v name="$1" '$0 ~ "^"name"\\(\\)" {f=1} f {print} f && /^}/ {exit}' "$SOURCE")"; }
for fn in ipv6_prefix_awk normalize_mac lower find_lan_ygg_prefix observed_ipv6_for_mac recall_lan_addresses; do load "$fn"; done
YGG_NET=ygg0
PREFIX='300:1111:2222::'
ubus() { printf '%s\n' "$PREFIX"; }
jsonfilter() { cat; }
eq '300:1111:2222:0:' "$(find_lan_ygg_prefix)"
# The same /64 in compressed and expanded forms must select only its addresses.
load ipv6_prefix_awk
LAN_YGG_PREFIX="$(find_lan_ygg_prefix)"; LAN_DEV=br-lan
ip() { printf '%s\n' '300:1111:2222::20 dev br-lan lladdr aa:bb:cc:dd:ee:ff STALE' '0300:1111:2222:0000::21 dev br-lan lladdr aa:bb:cc:dd:ee:ff STALE' '300:1111:2222:1::22 dev br-lan lladdr aa:bb:cc:dd:ee:ff STALE'; }
eq "$(printf '%s\n' '300:1111:2222::20' '0300:1111:2222:0000::21')" "$(observed_ipv6_for_mac aa:bb:cc:dd:ee:ff)"
LAN_CACHE_FILE="$TMP/cache"; LAN_STORE_FILE="$TMP/store"
printf '%s\n' 'aa:bb:cc:dd:ee:ff 300:1111:2222::20' 'aa:bb:cc:dd:ee:ff 300:1111:2222:1::22' > "$LAN_CACHE_FILE"
: > "$LAN_STORE_FILE"
eq '300:1111:2222::20' "$(recall_lan_addresses aa:bb:cc:dd:ee:ff)"
PREFIX='300::2222:0:0:0:0'
eq '300:0:0:2222:' "$(find_lan_ygg_prefix)"
PREFIX='300:1111:2222:3333::'
eq '300:1111:2222:3333:' "$(find_lan_ygg_prefix)"
echo 'PASS: compressed delegated /64 matches observed and remembered IPv6 addresses'
