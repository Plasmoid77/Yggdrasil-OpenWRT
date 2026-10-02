#!/bin/sh
# shellcheck disable=SC2034,SC2317,SC2329
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="$ROOT/deploy/deploy-openwrt-yggdrasil.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
load() { eval "$(awk -v name="$1" '$0 ~ "^"name"\\(\\)" {f=1} f {print} f && /^}/ {exit}' "$SOURCE")"; }
info() { :; }; ok() { :; }; DRY_RUN=0
load put_file
printf '#!/bin/sh\necho working\n' > "$TMP/hook"
cp "$TMP/hook" "$TMP/before"
chmod 600 "$TMP/hook"
put_file "$TMP/hook" 755 "$(cat "$TMP/hook")" test
[ "$(stat -c %a "$TMP/hook")" = 755 ] || fail 'unchanged hook mode not repaired'
if put_file "$TMP/hook" 755 'if then' test; then fail 'invalid shell accepted'; fi
cmp -s "$TMP/hook" "$TMP/before" || fail 'invalid shell replaced working hook'
put_file "$TMP/hook" 755 '#!/bin/sh
echo updated' test
sh -n "$TMP/hook"
DRY_RUN=1
put_file "$TMP/absent" 755 '#!/bin/sh' test
[ ! -e "$TMP/absent" ] || fail 'dry run wrote a file'
echo 'PASS: atomic hook writes preserve working content and repair permissions'
load backup_file
cp() { [ "$1" != -p ] || shift; [ "${FAIL_COPY:-0}" != 1 ] || { printf partial > "$2"; return 1; }; command cp "$@"; }
backup_file "$TMP/before" "$TMP/backup"
FAIL_COPY=1
if backup_file "$TMP/hook" "$TMP/backup"; then fail 'failed copy accepted'; fi
cmp -s "$TMP/backup" "$TMP/before" || fail 'failed copy destroyed good backup'
FAIL_COPY=0
# Use the actual lock and a sandbox DHCP file: a Pin committed after preflight
# must be included in the rollback image captured after obtaining the lock.
load dhcp_unlock
DHCP_LOCKED=0; DRY_RUN=0; BACKUP_DIR="$TMP/backups"; mkdir "$BACKUP_DIR"
printf old > "$TMP/dhcp"
backup_file "$TMP/dhcp" "$BACKUP_DIR/dhcp"
printf concurrent-pin > "$TMP/dhcp"
have() { command -v "$1" >/dev/null 2>&1; }
uci() { :; }; die() { fail "$*"; }
eval "$(awk '$0 ~ /^dhcp_lock\(\)/ {f=1} f {print} f && /^}/ {exit}' "$SOURCE" | sed "s|/var/lock/yggdrasil-status-dhcp.lock|$TMP/lock|g; s|/etc/config/dhcp|$TMP/dhcp|g")"
dhcp_lock
cmp -s "$TMP/dhcp" "$BACKUP_DIR/dhcp" || fail 'concurrent Pin missing from locked backup'
if ( flock -n "$TMP/lock" true ); then fail 'lock not held'; fi
dhcp_unlock
flock -n "$TMP/lock" true || fail 'lock not released'
# The final fatal stages must retain the lock; status installation needs it free.
if awk '/^stage_lan\(\)/,/^}/; /^stage_dns\(\)/,/^}/' "$SOURCE" | grep -q dhcp_unlock; then fail 'fatal stage releases lock early'; fi

echo 'PASS: failed backup preserves recovery image; locked backup includes concurrent Pin'

load rollback
CHANGED_NETWORK=0; CHANGED_DHCP=1; CHANGED_FIREWALL=0; CHANGED_DNS=0
warn() { :; }; uci() { :; }
printf live > "$TMP/dhcp"
cp "$TMP/dhcp" "$TMP/live-before"
FAIL_COPY=1
# Sandbox all rollback paths and service invocations.
eval "$(awk '$0 ~ /^rollback\(\)/ {f=1} f {print} f && /^}/ {exit}' "$SOURCE" | sed "s|/etc/config/|$TMP/|g; s|/etc/init.d/[a-z]*|true|g")"
if rollback; then fail 'partial rollback reported success'; fi
cmp -s "$TMP/dhcp" "$TMP/live-before" || fail 'failed restore damaged live config'
FAIL_COPY=0
rollback
cmp -s "$TMP/dhcp" "$BACKUP_DIR/dhcp" || fail 'successful rollback did not restore image'
echo 'PASS: failed rollback copy preserves live configuration and reports failure'

# Execute the production main sequence with stub stages. Signals during core
# edits must recover; after core completion they must not undo concurrent Pin.
cat > "$TMP/main-stubs" <<'STUBS'
set -u
RESTORE=0; DRY_RUN=0; RC_OK=0; SELF=test; VERSION=test
banner() { :; }; prompt_trusted() { :; }; warn() { :; }
die() { echo recovery >> "$EVENTS"; exit 1; }
stage_preflight() { :; }; stage_packages() { :; }; install_ygg_build() { :; }
install_hotplug_guard() { :; }; install_peer_hook() { :; }
stage_yggdrasil() { :; }; stage_wait() { :; }; stage_lan() { :; }
stage_firewall() { :; }
stage_dns() { [ "$SIGNAL_AT" != core ] || kill -TERM "$$"; }
dhcp_unlock() { echo unlock >> "$EVENTS"; }
stage_status() { echo status >> "$EVENTS"; kill -TERM "$$"; }
install_restore() { :; }; keep_on_sysupgrade() { :; }; stage_verify() { :; }
STUBS
awk '/^# ---+ main ---/ {f=1} f {print}' "$SOURCE" >> "$TMP/main-stubs"
for main_shell in sh 'busybox ash'; do
    for signal_at in core status; do
        : > "$TMP/events"
        # Intentional word splitting selects the shell plus its applet.
        # shellcheck disable=SC2086
        if EVENTS="$TMP/events" SIGNAL_AT="$signal_at" $main_shell "$TMP/main-stubs" >/dev/null 2>&1; then
            fail 'interrupted main succeeded'
        fi
        if [ "$signal_at" = core ]; then
            [ "$(cat "$TMP/events")" = recovery ] || fail 'signal during core edits did not recover'
        else
            [ "$(cat "$TMP/events")" = "$(printf 'unlock\nstatus')" ] || fail 'signal after unlock rolls back completed core'
        fi
    done
done
echo 'PASS: signal recovery ends before unlock and optional status installation'
