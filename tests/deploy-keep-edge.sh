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
for f in keep_list keep_on_sysupgrade ygg_edge_url restore_hook_text; do
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
RESTORE_HOOK='/etc/hotplug.d/iface/80-yggdrasil-restore'
SYSUPGRADE_CONF="$TMP/sysupgrade.conf"
printf '## This file contains files and directories that should\n/etc/example\n' > "$SYSUPGRADE_CONF"
DRY_RUN=0; DO_DNS=1
keep_on_sysupgrade
keep_on_sysupgrade
for k in "$HOTPLUG_FILE" "$PEER_HOOK" "$RESTORE_HOOK" "$DNS_HOOK" "$DNS_DIR"; do
    [ "$(grep -cxF "$k" "$SYSUPGRADE_CONF")" = 1 ] || fail "$k not listed exactly once: $(cat "$SYSUPGRADE_CONF")"
done
grep -qxF '/etc/example' "$SYSUPGRADE_CONF" || fail "an operator's own line was lost"
DO_DNS=0; printf '/etc/example\n' > "$SYSUPGRADE_CONF"; keep_on_sysupgrade
grep -q 60-yggdrasil-dns "$SYSUPGRADE_CONF" && fail 'DNS hook listed with --no-dns'
grep -qxF "$DNS_DIR" "$SYSUPGRADE_CONF" || fail 'the project directory (restore copy) not listed with --no-dns'
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

# 3. the restore hook: quiet when everything is there, --restore otherwise
IFACE=ygg0; LAN=lan; RESTORE_CONF="$TMP/r/restore.conf"; RESTORE_COPY="$TMP/r/deploy.sh"; STATUS_VIEW="$TMP/r/view.js"
mkdir -p "$TMP/r" "$TMP/bin"
restore_hook_text > "$TMP/hook"
sh -n "$TMP/hook" || fail 'restore hook does not parse'
busybox ash -n "$TMP/hook" || fail 'restore hook does not parse under BusyBox ash'
grep -qE '@(IFACE|LAN|CONF|COPY|VIEW)@' "$TMP/hook" && fail 'unexpanded placeholder in the restore hook'
printf 'echo restore "$@" >> %s/ran\n' "$TMP" > "$RESTORE_COPY"
: > "$STATUS_VIEW"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/logger"
printf '#!/bin/sh\ncase "$*" in *missing*) exit 1 ;; esac\nexit 0\n' > "$TMP/bin/apk"
printf '#!/bin/sh\necho /usr/sbin/yggdrasil\n' > "$TMP/bin/yggdrasil"
chmod 755 "$TMP/bin/"*
sed -e "s|/var/lock/yggdrasil-restore.lock|$TMP/lock|" -e 's|^\tsleep 10$|\t:|' \
    -e 's|) </dev/null >/dev/null 2>&1 &$|)|' -e "s|/tmp/yggdrasil-restore.log|$TMP/log|" "$TMP/hook" > "$TMP/hook.t"
conf() { printf 'iface ygg0\nlan lan\npackages %s\nstatus %s\nedge_hash %s\n' "$1" "$2" "$3" > "$RESTORE_CONF"; }
hook() { rm -f "$TMP/ran"; PATH="$TMP/bin:$PATH" ACTION="${2:-ifup}" INTERFACE="${1:-wan}" sh "$TMP/hook.t"; }
# the real hash of the stub binary (BusyBox ash runs its own sha256sum applet)
H="$(sha256sum "$TMP/bin/yggdrasil" | cut -d' ' -f1)"
conf yggdrasil,luci-proto-yggdrasil 1 "$H"; hook
[ ! -e "$TMP/ran" ] || fail 'restore ran although everything is there'
conf yggdrasil,missing-pkg 1 "$H"; hook
[ "$(cat "$TMP/ran" 2>/dev/null)" = 'restore --restore' ] || fail 'a missing package did not trigger --restore'
conf yggdrasil 1 "$H"; rm -f "$STATUS_VIEW"; hook
[ -e "$TMP/ran" ] || fail 'a missing status module did not trigger --restore'
: > "$STATUS_VIEW"; conf yggdrasil 1 def; hook
[ -e "$TMP/ran" ] || fail 'a replaced Yggdrasil binary did not trigger --restore'
conf yggdrasil 0 ''; rm -f "$STATUS_VIEW"; hook
[ ! -e "$TMP/ran" ] || fail 'status not chosen, feed Yggdrasil: restore should stay quiet'
conf yggdrasil,missing-pkg 1 "$H"; for ev in 'ifdown wan' 'ifup ygg0' 'ifup lan'; do
    # shellcheck disable=SC2086
    set -- $ev; hook "$2" "$1"; [ ! -e "$TMP/ran" ] || fail "reacted to $ev"
done
echo 'PASS: restore hook quiet when complete, --restore on a missing package, module or build'

echo 'deploy-keep-edge: all checks passed'
