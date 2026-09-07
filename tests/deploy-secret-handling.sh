#!/bin/sh
# shellcheck disable=SC2034,SC2317,SC2329
# Functions extracted with awk/eval deliberately hide their variable and
# function references from ShellCheck.

set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/deploy/deploy-openwrt-yggdrasil.sh"
TMP="$(mktemp -d /tmp/ygg-secret-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

extract_function() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\)" { found = 1 }
        found { print }
        found && /^}/ { exit }
    ' "$SCRIPT"
}

eval "$(extract_function uci_set)"

DRY_RUN=0
SECRET='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
ARGV_LOG="$TMP/argv"
STDIN_LOG="$TMP/stdin"

uci() {
    printf '%s\n' "$*" > "$ARGV_LOG"
    cat > "$STDIN_LOG"
}

uci_set 'network.ygg0.private_key' "$SECRET"

if grep -qF "$SECRET" "$ARGV_LOG"; then
    echo 'FAIL: private key reached uci argv' >&2
    exit 1
fi

grep -qF "set network.ygg0.private_key=$SECRET" "$STDIN_LOG" || {
    echo 'FAIL: private key was not sent to uci batch on stdin' >&2
    exit 1
}

echo 'PASS: private key is sent to uci over stdin, not argv'

validation_function="$(extract_function validate_private_key)"
[ -n "$validation_function" ] || {
    echo 'FAIL: reusable private-key validation is missing' >&2
    exit 1
}
eval "$validation_function"

die() { exit 1; }

(validate_private_key "$SECRET" 'test key') || {
    echo 'FAIL: a valid private key was rejected' >&2
    exit 1
}

BAD_SECRET="g${SECRET#?}"
if (validate_private_key "$BAD_SECRET" 'test key'); then
    echo 'FAIL: a non-hex private key passed final validation' >&2
    exit 1
fi

echo 'PASS: final private-key validation rejects malformed stored values'

eval "$(extract_function load_supplied_key)"

ok() { :; }
PRIVATE_KEY_FILE=''
SUPPLIED_KEY=''
export YGG_PRIVATE_KEY="$SECRET"
load_supplied_key

if [ "${YGG_PRIVATE_KEY+x}" = x ]; then
    echo 'FAIL: YGG_PRIVATE_KEY remains exported after loading' >&2
    exit 1
fi

[ "$SUPPLIED_KEY" = "$SECRET" ] || {
    echo 'FAIL: supplied environment key was not retained internally' >&2
    exit 1
}

echo 'PASS: YGG_PRIVATE_KEY is copied internally and removed from the environment'

ENV_IN_CHILD="$TMP/env-in-child"
KEY_FILE="$TMP/ygg.key"
printf '%s\n' "$SECRET" > "$KEY_FILE"
chmod 600 "$KEY_FILE"

tr() {
    if [ "${YGG_PRIVATE_KEY+x}" = x ]; then
        : > "$ENV_IN_CHILD"
    fi
    command tr "$@"
}

PRIVATE_KEY_FILE="$KEY_FILE"
SUPPLIED_KEY=''
export YGG_PRIVATE_KEY='ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
load_supplied_key

if [ "${YGG_PRIVATE_KEY+x}" = x ]; then
    echo 'FAIL: YGG_PRIVATE_KEY remains exported when a key file takes precedence' >&2
    exit 1
fi

[ ! -e "$ENV_IN_CHILD" ] || {
    echo 'FAIL: a key-loading child process inherited YGG_PRIVATE_KEY' >&2
    exit 1
}

[ "$SUPPLIED_KEY" = "$SECRET" ] || {
    echo 'FAIL: private-key file did not take precedence over the environment' >&2
    exit 1
}

echo 'PASS: key-file precedence also clears the environment before child processes'

changes_function="$(extract_function uci_changes_redacted)"
[ -n "$changes_function" ] || {
    echo 'FAIL: redacted UCI change reporter is missing' >&2
    exit 1
}
eval "$changes_function"

uci() {
    printf '%s\n' \
        "network.ygg0.private_key='$SECRET'" \
        "network.lan.ip6assign='64'"
}

uci_changes_redacted network > "$TMP/changes"

if grep -qF "$SECRET" "$TMP/changes"; then
    echo 'FAIL: private key reached UCI change report' >&2
    exit 1
fi

grep -qF "network.ygg0.private_key='<REDACTED>'" "$TMP/changes" || {
    echo 'FAIL: private-key change was not represented as redacted' >&2
    exit 1
}
grep -qF "network.lan.ip6assign='64'" "$TMP/changes" || {
    echo 'FAIL: non-secret UCI change disappeared from report' >&2
    exit 1
}

echo 'PASS: UCI change reports redact only private-key values'

if ! (
    umask 022
    eval "$(sed -n '/^set -u$/,/^VERSION=/p' "$SCRIPT")"
    [ "$(umask)" = '0077' ]
); then
    echo 'FAIL: deployer does not establish a private file-creation mask' >&2
    exit 1
fi

echo 'PASS: deployer establishes umask 077 before creating files'
