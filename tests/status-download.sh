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
for fn in status_valid_version status_expected_digest status_resolve_version \
    status_fetch status_verify status_acquire stage_status; do
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
    LIVE_VERSION="$(status_resolve_version)" || fail 'could not resolve the newest status release'
    status_valid_version "$LIVE_VERSION" || fail 'resolved version is not a valid label'
    LIVE_BASE="$STATUS_RELEASE_BASE/status-$LIVE_VERSION"
    LIVE_NAME="yggdrasil-status-$LIVE_VERSION.tar.gz"
    status_fetch "$LIVE_BASE/$LIVE_NAME" "$TMP/release.tar.gz" || fail 'release asset download failed'
    status_fetch "$LIVE_BASE/$LIVE_NAME.sha256" "$TMP/release.sha256" || fail 'published checksum download failed'
    LIVE_SHA="$(status_expected_digest "$TMP/release.sha256")" || fail 'published checksum is not a single entry'
    status_verify "$TMP/release.tar.gz" "$LIVE_SHA" || fail 'published archive does not match its published checksum'
    if [ -r "$ROOT/packages/$LIVE_NAME" ]; then
        cmp "$ROOT/packages/$LIVE_NAME" "$TMP/release.tar.gz" \
            || fail 'preserved archive differs from the published release of the same version'
    fi
    pass "newest published release $LIVE_VERSION resolves and matches its published checksum"
    exit 0
fi

[ -z "$STATUS_VERSION" ] || fail 'deployer still ships a hardcoded status version'
status_valid_version v5.2 || fail 'valid version rejected'
status_valid_version v5.2.1 || fail 'valid patch version rejected'
for bad in 'v5.2; rm -rf /' '../../etc' 'v05.2' 'status-v5.2' '' 'v5'; do
    if status_valid_version "$bad"; then fail "unsafe version accepted: [$bad]"; fi
done
case "$STATUS_RELEASE_BASE" in
    https://github.com/*/releases/download) : ;;
    *) fail 'release base is not a GitHub releases download path' ;;
esac
case "$STATUS_API" in
    https://api.github.com/repos/*/releases/latest) : ;;
    *) fail 'release lookup is not the releases/latest endpoint' ;;
esac
pass 'version tracking is dynamic, strictly validated and path-safe'

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
API_TAG='status-v9.9'
GOOD_SHA="$(sha256sum "$TMP/good.tar.gz" | awk '{print $1}')"
REL="$STATUS_RELEASE_BASE/status-v9.9/yggdrasil-status-v9.9.tar.gz"
status_fetch() {
    printf '%s\n' "$1" >> "$FETCH_LOG"
    case "$SCENARIO:$1" in
        *:"$STATUS_API")           printf '{"tag_name":"%s","draft":false}\n' "$API_TAG" > "$2" ;;
        noapi:*)                   return 1 ;;
        nosum:*.tar.gz.sha256)     return 1 ;;
        badsum:*.tar.gz.sha256)    printf '%s  a\n%s  b\n' "$GOOD_SHA" "$GOOD_SHA" > "$2" ;;
        wrongsum:*.tar.gz.sha256)  printf '%064d  x\n' 0 > "$2" ;;
        down:*.tar.gz)             return 1 ;;
        corrupt:*.tar.gz)          cp "$TMP/corrupt.tar.gz" "$2" ;;
        *:*.tar.gz.sha256)         printf '%s  x\n' "$GOOD_SHA" > "$2" ;;
        *:*.tar.gz)                cp "$TMP/good.tar.gz" "$2" ;;
        *) fail "unexpected fetch: $SCENARIO $1" ;;
    esac
}
STATUS_PKG=''

# The newest published release is resolved, then archive and checksum are
# fetched from that release and verified against each other.
STATUS_VERSION=''
: > "$FETCH_LOG"
status_acquire "$TMP/result.tar.gz" "$TMP/no-checkout" || fail 'release fetch failed'
cmp "$TMP/good.tar.gz" "$TMP/result.tar.gz"
[ "$STATUS_VERSION" = 'v9.9' ] || fail 'newest release version was not resolved'
[ "$(cat "$FETCH_LOG")" = "$(printf '%s\n' "$STATUS_API" "$REL" "$REL.sha256")" ] \
    || fail 'unexpected fetch sequence'
pass 'newest release is resolved and verified against its published checksum'

# An explicitly requested version must not consult the release list at all.
STATUS_VERSION='v9.9'
: > "$FETCH_LOG"
status_acquire "$TMP/result.tar.gz" "$TMP/no-checkout" || fail 'explicit version fetch failed'
if grep -Fq "$STATUS_API" "$FETCH_LOG"; then fail 'explicit version still queried the release list'; fi
pass 'an explicit --status-version bypasses release discovery'

# A tag that is not a well-formed status release can never reach a URL.
for API_TAG in 'v9.9' 'status-../../evil' 'status-v9.9; rm -rf /' 'latest'; do
    STATUS_VERSION=''
    : > "$FETCH_LOG"
    if status_acquire "$TMP/result.tar.gz" "$TMP/no-checkout"; then
        fail "unsafe release tag was accepted: [$API_TAG]"
    fi
    [ "$(cat "$FETCH_LOG")" = "$STATUS_API" ] || fail "unsafe tag [$API_TAG] reached a download URL"
done
API_TAG='status-v9.9'
STATUS_VERSION=''
: > "$FETCH_LOG"
SCENARIO='noapi'
if status_acquire "$TMP/result.tar.gz" "$TMP/no-checkout"; then fail 'unreachable release list was accepted'; fi
pass 'malformed tags and an unreachable release list refuse installation'

for SCENARIO in nosum badsum wrongsum corrupt down; do
    STATUS_VERSION=''
    : > "$FETCH_LOG"
    if status_acquire "$TMP/result.tar.gz" "$TMP/no-checkout"; then
        fail "unverified download accepted in scenario [$SCENARIO]"
    fi
done
SCENARIO='release'
pass 'missing, ambiguous, wrong and corrupt downloads all refuse installation'

# The checkout cache stays usable offline, but must prove its own bytes.
STATUS_VERSION='v9.9'
mkdir "$TMP/checkout"
cp "$TMP/good.tar.gz" "$TMP/checkout/yggdrasil-status-v9.9.tar.gz"
: > "$FETCH_LOG"
if status_acquire "$TMP/result.tar.gz" "$TMP/checkout"; then fail 'checkout package without a checksum was accepted'; fi
printf '%s  yggdrasil-status-v9.9.tar.gz\n' "$GOOD_SHA" > "$TMP/checkout/yggdrasil-status-v9.9.tar.gz.sha256"
status_acquire "$TMP/result.tar.gz" "$TMP/checkout" || fail 'offline checkout cache failed'
[ ! -s "$FETCH_LOG" ] || fail 'offline checkout used network'
cp "$TMP/corrupt.tar.gz" "$TMP/checkout/yggdrasil-status-v9.9.tar.gz"
if status_acquire "$TMP/result.tar.gz" "$TMP/checkout"; then fail 'corrupt checkout package was accepted'; fi
[ ! -s "$FETCH_LOG" ] || fail 'corrupt local cache silently fell back to the network'
pass 'checkout cache works offline but must prove its own checksum'

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
