#!/bin/sh
# Exercise real deployer functions against synthetic packages; never touch a router.
# shellcheck disable=SC2034,SC2317,SC2329
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/deploy/deploy-openwrt-yggdrasil.sh"
TMP="$(mktemp -d /tmp/ygg-download-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

extract() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\)" { found=1 }
        found { print }
        found && /^}/ { exit }
    ' "$SCRIPT"
}
# Load actual distribution pins, then real functions. Missing new helpers are
# tolerated here so the first regression also runs against the old deployer.
eval "$(sed -n '/^STATUS_[A-Z0-9_]*=/p' "$SCRIPT")"
for fn in status_fetch status_verify status_acquire stage_status; do
    eval "$(extract "$fn")"
done
info() { printf '%s\n' "$*" >> "$TMP/messages"; }
warn() { info "$@"; }
ok() { info "$@"; }
step() { info "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }
ubus() { return 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

if [ "${1:-}" = '--live' ]; then
    # No shell stubs for network/verification, no archive extraction or install.
    status_fetch "$STATUS_BASE/yggdrasil-status-$STATUS_VERSION.tar.gz" "$TMP/release.tar.gz"
    status_verify "$TMP/release.tar.gz" "$STATUS_SHA256"
    status_fetch "$STATUS_FALLBACK_BASE/yggdrasil-status-$STATUS_VERSION.tar.gz" "$TMP/mirror.tar.gz"
    status_verify "$TMP/mirror.tar.gz" "$STATUS_SHA256"
    cmp "$TMP/release.tar.gz" "$TMP/mirror.tar.gz"
    if [ -r "$ROOT/packages/yggdrasil-status-$STATUS_VERSION.tar.gz" ]; then
        cmp "$ROOT/packages/yggdrasil-status-$STATUS_VERSION.tar.gz" "$TMP/release.tar.gz"
    fi
    pass 'public release, immutable mirror and legacy archive are identical'
    exit 0
fi

if [ -r "$ROOT/packages/yggdrasil-status-$STATUS_VERSION.tar.gz" ]; then
    status_verify "$ROOT/packages/yggdrasil-status-$STATUS_VERSION.tar.gz" "$STATUS_SHA256" \
        || fail 'embedded pin disagrees with the preserved package'
fi
case "$STATUS_BASE" in
    */releases/download/status-"$STATUS_VERSION") : ;;
    *) fail 'default URL is not a versioned release' ;;
esac
printf '%s\n' "$STATUS_FALLBACK_BASE" | grep -Eq '/[0-9a-f]{40}/packages$' \
    || fail 'mirror URL is not pinned to a commit'
pass 'real release pins agree with the preserved distribution'

mkdir -p "$TMP/payload/module" "$TMP/work"
INSTALL_MARKER="$TMP/installed"
export INSTALL_MARKER
# Expand INSTALL_MARKER only when the generated fixture executes.
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf "installed\\n" >> "$INSTALL_MARKER"\n' > "$TMP/payload/module/install.sh"
tar -czf "$TMP/good.tar.gz" -C "$TMP/payload" module
printf 'not an archive\n' > "$TMP/corrupt.tar.gz"
STATUS_PKG="$TMP/good.tar.gz"
DO_STATUS=1
DRY_RUN=0
SELF='deploy-openwrt-yggdrasil.sh'
IFACE='ygg0'
TMPDIR="$TMP/work"
export TMPDIR

stage_status
[ ! -e "$INSTALL_MARKER" ] || fail 'local package without checksum was installed'
pass 'missing local checksum refuses installation'

STATUS_SHA256="$(sha256sum "$TMP/good.tar.gz" | awk '{print $1}')"
printf '%s  good.tar.gz\n' "$STATUS_SHA256" > "$STATUS_PKG.sha256"
stage_status
[ -f "$INSTALL_MARKER" ] || fail 'verified local package was not installed'
[ "$(wc -l < "$INSTALL_MARKER")" -eq 1 ] || fail 'local package installed more than once'
[ -z "$(ls -A "$TMP/work")" ] || fail 'temporary installation files were not cleaned'
rm "$INSTALL_MARKER"
pass 'verified local package installs once and cleans its private workspace'

printf 'broken\n' > "$STATUS_PKG.sha256"
stage_status
[ ! -e "$INSTALL_MARKER" ] || fail 'malformed checksum was accepted'
printf '%064d  good.tar.gz\n' 0 > "$STATUS_PKG.sha256"
stage_status
[ ! -e "$INSTALL_MARKER" ] || fail 'mismatched checksum was accepted'
printf '%s  good.tar.gz\n%s  other.tar.gz\n' "$STATUS_SHA256" "$STATUS_SHA256" > "$STATUS_PKG.sha256"
stage_status
[ ! -e "$INSTALL_MARKER" ] || fail 'ambiguous multi-entry checksum was accepted'
pass 'malformed, wrong and multi-entry local checksums refuse installation'

STATUS_PKG="$TMP/corrupt.tar.gz"
sha256sum "$STATUS_PKG" > "$STATUS_PKG.sha256"
stage_status >/dev/null 2>&1
[ ! -e "$INSTALL_MARKER" ] || fail 'invalid tar contents invoked an installer'
[ -z "$(ls -A "$TMP/work")" ] || fail 'invalid tar leaked temporary files'
pass 'verified but invalid archive is not installed and is cleaned'


FETCH_LOG="$TMP/fetches"
SCENARIO='release'
status_fetch() {
    printf '%s\n' "$1" >> "$FETCH_LOG"
    case "$SCENARIO:$1" in
        release:*) cp "$TMP/good.tar.gz" "$2" ;;
        mirror:"$STATUS_BASE"/*) printf 'partial\n' > "$2"; return 1 ;;
        mirror:"$STATUS_FALLBACK_BASE"/*) cp "$TMP/good.tar.gz" "$2" ;;
        corrupt:*) cp "$TMP/corrupt.tar.gz" "$2" ;;
        down:*) return 1 ;;
        *) fail "unexpected fetch: $SCENARIO $1" ;;
    esac
}
STATUS_PKG=''
: > "$FETCH_LOG"
status_acquire "$TMP/result.tar.gz" "$TMP/no-checkout" || fail 'release fetch failed'
cmp "$TMP/good.tar.gz" "$TMP/result.tar.gz"
[ "$(cat "$FETCH_LOG")" = "$STATUS_BASE/yggdrasil-status-$STATUS_VERSION.tar.gz" ] || fail 'release URL was not pinned'
pass 'release is the default network source and verified against the pin'

SCENARIO='mirror'
: > "$FETCH_LOG"
status_acquire "$TMP/result.tar.gz" "$TMP/no-checkout" || fail 'immutable mirror fallback failed'
cmp "$TMP/good.tar.gz" "$TMP/result.tar.gz"
[ "$(wc -l < "$FETCH_LOG")" -eq 2 ] || fail 'wrong fallback count'
[ "$(tail -n 1 "$FETCH_LOG")" = "$STATUS_FALLBACK_BASE/yggdrasil-status-$STATUS_VERSION.tar.gz" ] || fail 'fallback changed artifact version'
pass 'transport failure falls back to identical pinned bytes, not an older version'

SCENARIO='corrupt'
: > "$FETCH_LOG"
if status_acquire "$TMP/result.tar.gz" "$TMP/no-checkout"; then fail 'corrupt release was accepted'; fi
[ "$(wc -l < "$FETCH_LOG")" -eq 1 ] || fail 'checksum mismatch was hidden by fallback'
SCENARIO='down'
: > "$FETCH_LOG"
if status_acquire "$TMP/result.tar.gz" "$TMP/no-checkout"; then fail 'unavailable downloads were accepted'; fi
[ "$(wc -l < "$FETCH_LOG")" -eq 2 ] || fail 'unexpected downgrade or retry chain'
pass 'checksum failure does not downgrade; unavailable sources refuse installation'

mkdir "$TMP/checkout"
cp "$TMP/good.tar.gz" "$TMP/checkout/yggdrasil-status-$STATUS_VERSION.tar.gz"
: > "$FETCH_LOG"
status_acquire "$TMP/result.tar.gz" "$TMP/checkout" || fail 'offline checkout cache failed'
[ ! -s "$FETCH_LOG" ] || fail 'offline checkout used network'
cp "$TMP/corrupt.tar.gz" "$TMP/checkout/yggdrasil-status-$STATUS_VERSION.tar.gz"
if status_acquire "$TMP/result.tar.gz" "$TMP/checkout"; then fail 'corrupt checkout package was accepted'; fi
[ ! -s "$FETCH_LOG" ] || fail 'corrupt local cache silently fell back'
pass 'checkout cache works offline but cannot override pinned integrity'

if (have() { return 1; }; status_verify "$TMP/good.tar.gz" "$STATUS_SHA256"); then
    fail 'verification succeeded without sha256sum'
fi
if status_verify "$TMP/good.tar.gz" ''; then fail 'empty checksum accepted'; fi
pass 'verification is fail-closed when checksum/tool is missing'

STATUS_PKG="$TMP/good.tar.gz"
printf '%s  good.tar.gz\n' "$STATUS_SHA256" > "$STATUS_PKG.sha256"
DO_STATUS=0
stage_status
DO_STATUS=1
DRY_RUN=1
stage_status
[ ! -e "$INSTALL_MARKER" ] || fail 'dry-run or no-status installed a package'
[ -z "$(ls -A "$TMP/work")" ] || fail 'dry-run created installation files'
pass 'no-status and dry-run do not install or leave temporary files'

DRY_RUN=0
printf '#!/bin/sh\nexit 1\n' > "$TMP/payload/module/install.sh"
tar -czf "$TMP/failing.tar.gz" -C "$TMP/payload" module
STATUS_PKG="$TMP/failing.tar.gz"
sha256sum "$STATUS_PKG" > "$STATUS_PKG.sha256"
stage_status || fail 'optional installer failure aborted core deployment'
[ -z "$(ls -A "$TMP/work")" ] || fail 'failed installer leaked temporary files'
pass 'optional installer failure remains non-fatal and cleans up'
