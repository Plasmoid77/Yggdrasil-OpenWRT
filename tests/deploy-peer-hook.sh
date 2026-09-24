#!/bin/sh
# shellcheck disable=SC2034,SC2317,SC2329,SC2016
# install_peer_hook writes /etc/hotplug.d/iface/70-yggdrasil-peers: when an
# uplink comes up, the configured peers that are not up are re-added through
# the admin socket (removepeer + addpeer), which restarts Yggdrasil's attempts
# at once instead of after its growing pause. The hook runs here against
# stubbed yggdrasilctl, jsonfilter and UCI helpers.

set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/deploy/deploy-openwrt-yggdrasil.sh"
TMP="$(mktemp -d /tmp/ygg-peerhook-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

extract_function() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\)" { found = 1 }
        found { print }
        found && /^}$/ { exit }
    ' "$SCRIPT"
}
eval "$(extract_function peer_hook_text)"
fail() { echo "FAIL: $*" >&2; exit 1; }

IFACE='ygg0'; LAN='lan'
peer_hook_text > "$TMP/hook"
sh -n "$TMP/hook" || fail 'hook does not parse'
busybox ash -n "$TMP/hook" || fail 'hook does not parse under BusyBox ash'
grep -qE '@(IFACE|LAN)@' "$TMP/hook" && fail "unexpanded placeholder: $(grep -E '@(IFACE|LAN)@' "$TMP/hook")"
echo 'PASS: hook written, parses, placeholders expanded'

# Test copy: fixture paths instead of the router's, no sleep, synchronous.
mkdir -p "$TMP/bin" "$TMP/run"
: > "$TMP/run/ygg0.sock.present"
cat > "$TMP/functions.sh" <<'FN'
config_load() { :; }
config_foreach() {
    for s in p0 p1 p2 p3; do "$1" "$s"; done
}
config_get() {
    case "$1 $2 $3" in
        'uri p0 address') eval "$1='tls://a.example:1'" ;;
        'uri p1 address') eval "$1='tls://b.example:2?key=abc'" ;;
        'uri p2 address') eval "$1='wss://c.example:443'" ;;
        'uri p3 address') eval "$1='tls://[fe80::1%25eth0]:9'" ;;
        'iface p3 interface') eval "$1='eth0'" ;;
        *) eval "$1=''" ;;
    esac
}
FN
cat > "$TMP/bin/yggdrasilctl" <<STUB
#!/bin/sh
echo "\$*" >> "$TMP/calls"
STUB
cat > "$TMP/bin/jsonfilter" <<STUB
#!/bin/sh
printf '%s\n' "\${UP_REMOTES:-}"
STUB
cat > "$TMP/bin/logger" <<STUB
#!/bin/sh
echo "\$*" >> "$TMP/log"
STUB
chmod 755 "$TMP/bin/"*
sed -e "s|\[ -S '/tmp/yggdrasil/ygg0.sock' \]|[ -e '$TMP/run/ygg0.sock.present' ]|" \
    -e "s|/var/lock/yggdrasil-peers.lock|$TMP/lock|" \
    -e 's|^\tsleep 5$|\t:|' \
    -e "s|\. /lib/functions.sh|. '$TMP/functions.sh'|" \
    -e 's|) </dev/null >/dev/null 2>&1 &$|)|' \
    "$TMP/hook" > "$TMP/hook.t"
grep -q 'sleep 5' "$TMP/hook.t" && fail 'test copy still sleeps'
grep -q "$TMP/functions.sh" "$TMP/hook.t" || fail 'test copy still loads /lib/functions.sh'

run_hook() { : > "$TMP/calls"; : > "$TMP/log"; PATH="$TMP/bin:$PATH" UP_REMOTES="$1" ACTION="$2" INTERFACE="$3" sh "$TMP/hook.t"; }

# 1. uplink up, a.example up, b and c down: only b and c are re-added, with their full URI
run_hook 'tls://a.example:1' ifup LTE_Fibocom_860
grep -q 'a.example' "$TMP/calls" && fail "an established peer was touched: $(cat "$TMP/calls")"
grep -qF 'removepeer uri=tls://b.example:2?key=abc' "$TMP/calls" || fail "b not removed: $(cat "$TMP/calls")"
grep -qF 'addpeer uri=tls://b.example:2?key=abc' "$TMP/calls" || fail "b not re-added: $(cat "$TMP/calls")"
grep -qF 'addpeer uri=wss://c.example:443' "$TMP/calls" || fail "c not re-added: $(cat "$TMP/calls")"
grep -q 'fe80' "$TMP/calls" && fail 'an interface peer was touched'
[ "$(grep -c '^-endpoint=.* addpeer ' "$TMP/calls")" -eq 2 ] || fail "want two addpeer calls: $(cat "$TMP/calls")"
echo 'PASS: peers that are down are retried, established and interface peers are not'

# 2. a query string does not hide an established peer (remote is shown without it)
run_hook "$(printf '%s\n' 'tls://a.example:1' 'tls://b.example:2' 'wss://c.example:443')" ifup wan
[ ! -s "$TMP/calls" ] || { grep -q 'removepeer' "$TMP/calls" && fail "an established peer was re-added: $(cat "$TMP/calls")"; }
echo 'PASS: all peers up: nothing to do'

# 3. other events and our own interfaces are ignored
for ev in 'ifdown wan' 'ifupdate wan' 'ifup ygg0' 'ifup lan' 'ifup loopback'; do
    # shellcheck disable=SC2086
    set -- $ev
    run_hook '' "$1" "$2"
    [ ! -s "$TMP/calls" ] || fail "reacted to $ev: $(cat "$TMP/calls")"
done
echo 'PASS: ifdown, ifupdate and the Ygg/LAN/loopback interfaces are ignored'

# 4. no admin socket (Yggdrasil not running): nothing to do
rm -f "$TMP/run/ygg0.sock.present"
run_hook '' ifup wan
[ ! -s "$TMP/calls" ] || fail 'ran without the admin socket'
echo 'PASS: no socket, no action'

echo 'deploy-peer-hook: all checks passed'
