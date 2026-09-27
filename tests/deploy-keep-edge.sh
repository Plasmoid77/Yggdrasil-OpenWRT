#!/bin/sh
# shellcheck disable=SC2034,SC2317,SC2329
# keep_on_sysupgrade lists the deployer's own files outside /etc/config in
# /etc/sysupgrade.conf (idempotently); ygg_edge_url picks this project's newest
# Yggdrasil build for the router's architecture and nothing else.

set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/deploy/deploy-openwrt-yggdrasil.sh"
TMP="$(mktemp -d /tmp/ygg-keep-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

extract_function() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\)" { found = 1 }
        found { print }
        found && /^}$/ { exit }
    ' "$SCRIPT"
}
for f in keep_list keep_on_sysupgrade ygg_edge_url; do
    body="$(extract_function "$f")"
    [ -n "$body" ] || { echo "FAIL: function $f not found in deployer" >&2; exit 1; }
    eval "$body"
done
fail() { echo "FAIL: $*" >&2; exit 1; }
info() { :; }
die() { fail "die: $*"; }

# 1. the keep list: hooks always, the DNS files only with the DNS module
HOTPLUG_FILE='/etc/hotplug.d/net/50-yggdrasil-pending'
PEER_HOOK='/etc/hotplug.d/iface/70-yggdrasil-peers'
DNS_HOOK='/etc/hotplug.d/iface/60-yggdrasil-dns'
DNS_DIR='/etc/yggdrasil-openwrt'
SYSUPGRADE_CONF="$TMP/sysupgrade.conf"
printf '## This file contains files and directories that should\n/etc/example\n' > "$SYSUPGRADE_CONF"
DRY_RUN=0; DO_DNS=1
keep_on_sysupgrade
keep_on_sysupgrade
for k in "$HOTPLUG_FILE" "$PEER_HOOK" "$DNS_HOOK" "$DNS_DIR"; do
    [ "$(grep -cxF "$k" "$SYSUPGRADE_CONF")" = 1 ] || fail "$k not listed exactly once: $(cat "$SYSUPGRADE_CONF")"
done
grep -qxF '/etc/example' "$SYSUPGRADE_CONF" || fail "an operator's own line was lost"
DO_DNS=0; printf '/etc/example\n' > "$SYSUPGRADE_CONF"; keep_on_sysupgrade
grep -q yggdrasil-openwrt "$SYSUPGRADE_CONF" && fail 'DNS files listed with --no-dns'
DO_DNS=1; printf '/etc/example\n' > "$SYSUPGRADE_CONF"; DRY_RUN=1; keep_on_sysupgrade
[ "$(cat "$SYSUPGRADE_CONF")" = '/etc/example' ] || fail 'dry run wrote the keep list'
echo 'PASS: own files listed once in sysupgrade.conf, operator lines kept, dry run writes nothing'

# 2. the newest build for this architecture, from this repository only
STATUS_RELEASE_BASE='https://github.com/Plasmoid77/Yggdrasil-OpenWRT/releases/download'
YGG_RELEASES_API='https://api.example/releases'
status_fetch() { : > "$2"; }
pkg_arch() { echo aarch64_cortex-a53; }
URLS=''
jsonfilter() { printf '%s\n' "$URLS"; }
B="$STATUS_RELEASE_BASE"
URLS="$B/status-v6.5/yggdrasil-status-v6.5.tar.gz
https://evil.example/releases/download/yggdrasil-9.9.9/yggdrasil-9.9.9_aarch64_cortex-a53.apk
$B/yggdrasil-0.5.15-r1-mips/yggdrasil-0.5.15-r1_mipsel_24kc.apk
$B/yggdrasil-0.5.14-r1-aarch64/yggdrasil-0.5.14-r1_aarch64_cortex-a53.apk.sha256
$B/yggdrasil-0.5.14-r1-aarch64/yggdrasil-0.5.14-r1_aarch64_cortex-a53.apk
$B/yggdrasil-0.5.13-r1-aarch64/yggdrasil-0.5.13-r1_aarch64_cortex-a53.apk"
[ "$(ygg_edge_url)" = "$B/yggdrasil-0.5.14-r1-aarch64/yggdrasil-0.5.14-r1_aarch64_cortex-a53.apk" ] \
    || fail "picked $(ygg_edge_url)"
URLS="$B/yggdrasil-x/yggdrasil-1_aarch64_cortex-a53.apk;rm -rf
$B/yggdrasil-0.5.15-r1-mips/yggdrasil-0.5.15-r1_mipsel_24kc.apk"
if ygg_edge_url >/dev/null; then fail 'accepted a foreign-arch or malformed URL'; fi
echo 'PASS: the newest same-arch build of this repository, nothing else'

echo 'deploy-keep-edge: all checks passed'
