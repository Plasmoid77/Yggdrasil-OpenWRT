#!/bin/sh
# shellcheck disable=SC2034,SC2317,SC2329
# The deployer's argument parser is extracted with sed/awk and evaluated here,
# which hides its variable and function references from ShellCheck.
#
# Deployer 1.7.0 made the peer list optional: a run without --peer/--peers-file
# keeps the existing peer sections instead of failing before it starts. This
# guards the parser side of that contract; the UCI side needs a router.

set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/deploy/deploy-openwrt-yggdrasil.sh"

extract_function() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\)" { found = 1 }
        found { print }
        found && /^}$/ { exit }
    ' "$SCRIPT"
}

# defaults block, then the helpers and the option loop the parser relies on
eval "$(sed -n '/^set -u$/,/^VERSION=/p' "$SCRIPT" | sed '/^set -u$/d')"
eval "$(sed -n '/^# -* defaults -*$/,/^usage() {$/p' "$SCRIPT" | sed '$d')"
eval "$(extract_function add_peer)"
eval "$(extract_function add_trusted)"
eval "$(extract_function add_dns_host)"
eval "$(extract_function status_valid_version)"
PARSER="$(sed -n '/^while \[ \$# -gt 0 \]; do$/,/^done$/p' "$SCRIPT")"
[ -n "$PARSER" ] || { echo 'FAIL: option loop not found in deployer' >&2; exit 1; }

DIED=''
die()   { DIED="$*"; }
usage() { :; }

# 1. no peers at all is not an error any more
set -- --trusted 200::1 -y
eval "$PARSER"
if [ -n "$DIED" ]; then
    echo "FAIL: a run without --peer was rejected: $DIED" >&2
    exit 1
fi
[ -z "$PEERS" ] || { echo 'FAIL: PEERS is not empty without --peer' >&2; exit 1; }
grep -qF 'no peers given; --peer or --peers-file is required' "$SCRIPT" && {
    echo 'FAIL: the mandatory-peers check is still present' >&2
    exit 1
}
echo 'PASS: the peer list is optional at the command line'

# 2. the peers stage keeps existing sections when none were given
# shellcheck disable=SC2016
grep -qF 'if [ -z "$PEERS" ]; then' "$SCRIPT" || {
    echo 'FAIL: peers stage does not branch on an empty peer list' >&2
    exit 1
}
echo 'PASS: peers stage leaves existing sections alone without --peer'

# 3. peers that are given are still validated and collected
DIED=''; PEERS=''
set -- --peer tls://a.example:443 --peer wss://b.example/ygg
eval "$PARSER"
[ -z "$DIED" ] || { echo "FAIL: valid peers rejected: $DIED" >&2; exit 1; }
[ "$(printf '%s\n' "$PEERS" | wc -l | tr -d ' ')" = 2 ] || {
    echo 'FAIL: two --peer options did not yield two peers' >&2
    exit 1
}
DIED=''; PEERS=''
set -- --peer http://a.example
eval "$PARSER"
[ -n "$DIED" ] || { echo 'FAIL: a peer with a bad scheme was accepted' >&2; exit 1; }
echo 'PASS: given peers are still validated and collected'

# peers get a capped reconnection backoff unless they carry their own
eval "$(grep '^PEER_MAXBACKOFF=' "$SCRIPT")"
eval "$(extract_function peer_with_maxbackoff)"
for pair in 'tls://a.example:1|tls://a.example:1?maxbackoff=1m' \
            'tls://a.example:1?key=abc|tls://a.example:1?key=abc&maxbackoff=1m' \
            'tls://a.example:1?maxbackoff=5m|tls://a.example:1?maxbackoff=5m' \
            'wss://b.example:443/p?x=1&maxbackoff=30s|wss://b.example:443/p?x=1&maxbackoff=30s'; do
    got="$(peer_with_maxbackoff "${pair%%|*}")"
    [ "$got" = "${pair#*|}" ] || { echo "FAIL: maxbackoff for ${pair%%|*}: got $got" >&2; exit 1; }
done
echo 'PASS: peers get maxbackoff=1m unless they set their own'
