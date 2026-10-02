#!/bin/sh
# shellcheck disable=SC2030,SC2031,SC2034,SC2317,SC2329
# What a run records for the restore hook (restore.conf), what --restore does
# with it after a sysupgrade, and how the Yggdrasil package is chosen: the
# feed's by default, this project's build with --ygg-edge only while it is the
# newer one, a local build with --ygg-pkg, the feed's again with --ygg-feed.
# The functions are extracted from the deployer; apk, downloads and the stages
# around them are stubs that record what they were asked to do.
# set -u only, as the deployer itself runs: a failing $(...) is data here, not an abort
set -u
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/deploy/deploy-openwrt-yggdrasil.sh"
TMP="$(mktemp -d /tmp/ygg-restore-test.XXXXXX)"
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
for f in put_file restore_disable restore_conf_get restore_hook_text install_restore restore_run \
         ygg_pkg_version ygg_feed_version apk_update ver_older ygg_restart_if_changed ygg_use_feed install_ygg_build \
         keep_list keep_on_sysupgrade; do
    body="$(extract_function "$f")"
    [ -n "$body" ] || { echo "FAIL: function $f not found in deployer" >&2; exit 1; }
    eval "$body"
done

fail() { echo "FAIL: $*" >&2; exit 1; }
LOG="$TMP/log"
info() { printf 'info %s\n' "$*" >> "$LOG"; }
ok()   { printf 'ok %s\n' "$*" >> "$LOG"; }
warn() { printf 'warn %s\n' "$*" >> "$LOG"; }
step() { :; }
die()  { printf 'die %s\n' "$*" >> "$LOG"; exit 3; }

DNS_DIR="$TMP/etc"
RESTORE_CONF="$DNS_DIR/restore.conf"
RESTORE_COPY="$DNS_DIR/deploy.sh"
RESTORE_HOOK="$TMP/hook"
STATUS_VIEW="$TMP/view.js"
APK_WORLD="$TMP/world"
HOTPLUG_FILE=/h; PEER_HOOK=/p; DNS_HOOK=/d
IFACE=ygg0; LAN=lan; DRY_RUN=0

# apk: the installed version lives in $TMP/inst, the feed's in $TMP/feed;
# every add is recorded, index refreshes apart. A local .apk installs $EDGE.
INST="$TMP/inst"; FEED="$TMP/feed"; CALLS="$TMP/calls"; UPDATES="$TMP/updates"
apk() {
    case "$1" in
        list)    [ -s "$INST" ] && echo "yggdrasil-$(cat "$INST") aarch64_cortex-a53 {feeds} (LGPL-3.0-only) [installed]"; return 0 ;;
        update)  echo update >> "$UPDATES"; return 0 ;;
        search)  [ -s "$UPDATES" ] || return 0   # no index before an update (RAM cache)
                 echo "yggdrasil-$(cat "$FEED")"; return 0 ;;
        version) awk -v a="$3" -v b="$4" 'BEGIN {
                     n = split(a, x, /[^0-9]+/); m = split(b, y, /[^0-9]+/)
                     for (i = 1; i <= (n > m ? n : m); i++) {
                         if (x[i] + 0 < y[i] + 0) { print "<"; exit }
                         if (x[i] + 0 > y[i] + 0) { print ">"; exit }
                     }
                     print "=" }'; return 0 ;;
        add)     shift; echo "apk add $*" >> "$CALLS"
                 case "$*" in
                     *--allow-untrusted*) echo "$EDGE" > "$INST" ;;
                     yggdrasil=*) echo "${1#yggdrasil=}" > "$INST"; echo "$1" > "$APK_WORLD" ;;
                     yggdrasil) echo yggdrasil > "$APK_WORLD" ;;
                 esac; return 0 ;;
    esac
}
ygg_binary_hash() { cat "$INST" 2>/dev/null; }
ifstatus() { echo '{"up": false}'; }
jsonfilter() { echo false; }
pkg_arch() { echo aarch64_cortex-a53; }
ygg_edge_url() { echo "$STATUS_RELEASE_BASE/yggdrasil-$EDGE-aarch64/yggdrasil-${EDGE}_aarch64_cortex-a53.apk"; }
status_fetch() {
    case "$1" in
        "$DEPLOYER_URL") printf "#!/bin/sh\nVERSION='%s'\n" "$VERSION" > "$2" ;;
        *.apk|*.apk.sha256) : > "$2" ;;
        *) return 1 ;;
    esac
}
status_expected_digest() { echo 0; }
status_verify() { return 0; }
stage_packages() { echo stage_packages >> "$CALLS"; }
stage_status() { echo "stage_status ${STATUS_VERSION:-newest}" >> "$CALLS"; : > "$STATUS_VIEW"; }
get() { restore_conf_get "$1"; }
reset() {
    : > "$LOG"; : > "$CALLS"; : > "$UPDATES"; APK_UPDATED=0; DRY_RUN=0
    YGG_EDGE=0; YGG_FEED=0; YGG_PKG=''; STATUS_VERSION=''; STATUS_PKG=''
    DO_JUMPER=1; DO_STATUS=1
}
expect() { [ "$(get "$1")" = "$2" ] || fail "$3: $1 is [$(get "$1")], expected [$2]"; }

# 1. what a run records
reset; echo 0.5.12-r1 > "$INST"; echo 0.5.12-r1 > "$FEED"
install_restore
expect packages yggdrasil,luci-proto-yggdrasil,yggdrasil-jumper,iputils-arping 'default run'
expect status_src newest 'default run'
expect edge_version '' 'default run'
if [ ! -f "$RESTORE_COPY" ] || [ ! -f "$RESTORE_HOOK" ]; then fail 'deployer copy or hook missing'; fi

reset; echo 0.5.14-r1 > "$INST"; YGG_EDGE=1; install_restore
expect edge_version 0.5.14-r1 '--ygg-edge'; expect edge_src release '--ygg-edge'
reset; install_restore
expect edge_version 0.5.14-r1 'a later run without the switch'
expect edge_src release 'a later run without the switch'
reset; YGG_FEED=1; install_restore
expect edge_version '' '--ygg-feed'
reset; printf 'edge_hash 0.5.14-r1\nedge_src release\n' > "$RESTORE_CONF"; install_restore
expect edge_version 0.5.14-r1 'a 2.x restore.conf (binary hash) on the same build'
reset; YGG_PKG=/root/y.apk; install_restore
expect edge_src local '--ygg-pkg'
reset; DO_JUMPER=0; DO_STATUS=0; STATUS_VERSION=v7.0; install_restore
expect packages yggdrasil,luci-proto-yggdrasil 'no jumper, no status'
expect status_src v7.0 'a pinned status version'
reset; STATUS_PKG=/root/s.tar.gz; install_restore
expect status_src local '--status-pkg'
# a write failure costs the restore hook, never the run
reset; (RESTORE_CONF="$TMP/missing/restore.conf"; install_restore) || fail 'restore.conf write failure was fatal'
grep -q '^warn .*restore hook removed' "$LOG" || fail "write failure not reported: $(cat "$LOG")"
echo 'PASS: restore.conf records packages, status source and the Yggdrasil build; write failures are not fatal'

# 2. --restore after a sysupgrade
conf() { printf 'iface ygg0\nlan lan\npackages yggdrasil\njumper 1\nstatus 1\nstatus_src %s\nedge_version %s\nedge_src %s\n' "$1" "$2" "$3" > "$RESTORE_CONF"; }
reset; : > "$STATUS_VIEW"; conf newest 0.5.14-r1 release
echo 0.5.12-r1 > "$INST"; echo 0.5.12-r1 > "$FEED"; EDGE=0.5.14-r1
restore_run
[ "$(cat "$INST")" = 0.5.14-r1 ] || fail 'the build was not put back over the older feed version'
expect edge_version 0.5.14-r1 'build restored'
grep -q 'allow-untrusted' "$CALLS" || fail 'build not installed from the verified file'

reset; conf newest 0.5.14-r1 release; echo 0.5.15-r1 > "$INST"
restore_run
grep -q 'apk add' "$CALLS" && fail 'a newer feed version was replaced'
expect edge_version '' 'feed overtook the build'
grep -q '^info .*newer than this project' "$LOG" || fail 'keeping the newer feed version not reported'

reset; conf newest 0.5.14-r1 local; echo 0.5.12-r1 > "$INST"
restore_run
expect edge_version '' 'a lost --ygg-pkg build'
grep -q '^warn .*local Yggdrasil build' "$LOG" || fail 'lost local build not reported'

reset; conf newest 0.5.14-r1 release; echo 0.5.12-r1 > "$INST"; echo 0.5.16-r1 > "$FEED"
restore_run
[ "$(cat "$INST")" = 0.5.16-r1 ] || fail 'the feed caught up, but its version was not installed'
expect edge_version '' 'the feed caught up'
grep -q 'allow-untrusted' "$CALLS" && fail 'the older build was downloaded although the feed is newer'

reset; echo 0.5.12-r1 > "$FEED"; echo 0.5.12-r1 > "$INST"; rm -f "$STATUS_VIEW"; conf v7.0 '' ''
restore_run
grep -qx 'stage_status v7.0' "$CALLS" || fail "pinned status version not restored: $(cat "$CALLS")"
reset; rm -f "$STATUS_VIEW"; conf local '' ''
if restore_run; then fail 'a lost local status build reported success'; fi
expect status 0 'a lost local status build'
echo 'PASS: --restore puts back an older-than-recorded build, keeps a newer feed version, forgets lost local builds'

# 3. the package choice itself
reset; echo 0.5.14-r1 > "$INST"; echo 0.5.12-r1 > "$FEED"; echo 'yggdrasil><Q1abc=' > "$APK_WORLD"
YGG_FEED=1; install_ygg_build
[ "$(cat "$CALLS")" = "$(printf 'apk add yggdrasil=0.5.12-r1\napk add yggdrasil')" ] || fail "--ygg-feed: $(cat "$CALLS")"
[ "$(cat "$APK_WORLD")" = yggdrasil ] || fail 'the version pin was left in the apk world'
reset; YGG_FEED=1; install_ygg_build
[ ! -s "$CALLS" ] || fail "--ygg-feed on the feed's version changed something: $(cat "$CALLS")"
reset; echo 0.5.12-r1 > "$INST"; echo 0.5.14-r1 > "$FEED"; EDGE=0.5.14-r1; YGG_EDGE=1
install_ygg_build
grep -q 'allow-untrusted' "$CALLS" && fail '--ygg-edge downloaded a build that is not newer than the feed'
[ "$YGG_EDGE" -eq 0 ] || fail '--ygg-edge still recorded although the feed was used'
reset; echo 0.5.12-r1 > "$INST"; echo 0.5.12-r1 > "$FEED"; EDGE=0.5.14-r1; YGG_EDGE=1
install_ygg_build
[ "$(cat "$INST")" = 0.5.14-r1 ] || fail '--ygg-edge did not install the newer build'
# the index is refreshed once per run before the feed is read, never on a dry run
[ "$(wc -l < "$UPDATES")" -eq 1 ] || fail "--ygg-edge: $(wc -l < "$UPDATES") index refreshes, expected 1"
reset; echo 0.5.12-r1 > "$INST"; echo 0.5.14-r1 > "$FEED"; EDGE=0.5.14-r1; YGG_EDGE=1
install_ygg_build
[ "$(wc -l < "$UPDATES")" -eq 1 ] || fail "--ygg-edge falling back to the feed refreshed $(wc -l < "$UPDATES") times"
reset; echo 0.5.14-r1 > "$INST"; echo 0.5.12-r1 > "$FEED"; DRY_RUN=1; YGG_FEED=1
install_ygg_build
[ ! -s "$UPDATES" ] || fail '--dry-run refreshed the package index'
grep -q "^info would install the feed's yggdrasil (version unknown until apk update)" "$LOG" || fail "dry run without an index: $(cat "$LOG")"
echo 'PASS: --ygg-edge only while newer than the feed, --ygg-feed back to the feed without a version pin'

# 4. the keep list is not worth a rollback either
if [ "$(id -u)" -ne 0 ]; then
    reset; SYSUPGRADE_CONF="$TMP/sysupgrade.conf"; DO_DNS=1
    printf '/etc/example' > "$SYSUPGRADE_CONF"
    keep_on_sysupgrade
    [ "$(sed -n 1p "$SYSUPGRADE_CONF")" = /etc/example ] || fail 'an operator line without a newline was glued to ours'
    : > "$TMP/ro.conf"; chmod 444 "$TMP/ro.conf"; SYSUPGRADE_CONF="$TMP/ro.conf"
    (keep_on_sysupgrade) || fail 'an unwritable sysupgrade.conf was fatal'
    grep -q '^warn cannot write' "$LOG" || fail 'unwritable sysupgrade.conf not reported'
    echo 'PASS: keep list survives a missing final newline and an unwritable file'
fi

echo 'deploy-restore: all checks passed'
