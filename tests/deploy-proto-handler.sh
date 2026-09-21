#!/bin/sh
# shellcheck disable=SC2034,SC2317,SC2329,SC2016
# patch_proto_handler inserts a wait for the TUN device into the stock netifd
# yggdrasil proto handler (cold-boot race: the link-up update is sent before
# the device exists and the interface stays pending). The function is extracted
# from the deployer and pointed at a fixture. SC2016: the fixture and the
# expected lines are literal handler text.

set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/deploy/deploy-openwrt-yggdrasil.sh"
TMP="$(mktemp -d /tmp/ygg-proto-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
HANDLER="$TMP/yggdrasil.sh"

body="$(awk '
    $0 ~ "^patch_proto_handler\\(\\)" { found = 1 }
    found { print }
    found && /^}$/ { exit }
' "$SCRIPT" | sed "s|/lib/netifd/proto/yggdrasil.sh|$HANDLER|")"
[ -n "$body" ] || { echo 'FAIL: patch_proto_handler not found in deployer' >&2; exit 1; }
eval "$body"

DIED=''; OKD=''; INFOD=''
die()  { DIED="${DIED}${*}
"; }
ok()   { OKD="${OKD}${*}
"; }
info() { INFOD="${INFOD}${*}
"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
reset() { DIED=''; OKD=''; INFOD=''; DRY_RUN=0; }

# Shape of the stock handler around the anchor (tabs, as upstream).
write_fixture() {
    printf '%s\n' \
        '#!/bin/sh' \
        'proto_yggdrasil_setup() {' \
        '	local config="$1"' \
        '	proto_run_command "$config" /usr/sbin/yggdrasil -useconffile "${ygg_cfg}"' \
        '	proto_init_update "$config" 1' \
        '	proto_send_update "$config"' \
        '}' > "$HANDLER"
}

# 1. Insert once, right after the anchor, and the result still parses and
#    is still executable (netifd runs the handler; the deployer's umask is 077).
reset; write_fixture; chmod 755 "$HANDLER"; umask 077
patch_proto_handler
[ -z "$DIED" ] || fail "unexpected die: $DIED"
[ -x "$HANDLER" ] || fail 'handler lost its exec bit'
[ "$(stat -c %a "$HANDLER" 2>/dev/null || busybox stat -c %a "$HANDLER")" = 755 ] || fail 'handler mode changed'
sh -n "$HANDLER" || fail 'patched handler does not parse'
[ "$(grep -c 'wait for the TUN device' "$HANDLER")" = 1 ] || fail 'wait not inserted exactly once'
awk 'prev ~ /proto_run_command/ && $0 !~ /wait for the TUN device/ { exit 1 } { prev = $0 }' "$HANDLER" \
    || fail 'wait is not directly after proto_run_command'
grep -q '^	while \[ "\$_i" -lt 10 \] && \[ ! -d "/sys/class/net/\${config}" \]; do$' "$HANDLER" \
    || fail 'wait loop line differs from the expected text (tabs, quoting)'
grep -q 'sleep 1$' "$HANDLER" || fail 'loop must sleep whole seconds (BusyBox sleep takes no fractions)'
[ ! -e "$HANDLER.new" ] || fail 'temporary file left behind'

# 2. Second run is a no-op.
before="$(cat "$HANDLER")"; reset
patch_proto_handler
[ "$(cat "$HANDLER")" = "$before" ] || fail 'second run changed the handler'
case "$OKD" in *'already waits'*) ;; *) fail "second run did not report the existing wait: $OKD" ;; esac

# 3. Unknown layout is refused, nothing written.
reset; printf '#!/bin/sh\nproto_yggdrasil_setup() { :; }\n' > "$HANDLER"; before="$(cat "$HANDLER")"
patch_proto_handler
case "$DIED" in *'unexpected proto handler layout'*) ;; *) fail "no die on unknown layout: $DIED" ;; esac
[ "$(cat "$HANDLER")" = "$before" ] || fail 'handler modified despite the refusal'

# 4. Dry run reports and leaves the file alone.
reset; write_fixture; DRY_RUN=1; before="$(cat "$HANDLER")"
patch_proto_handler
[ "$(cat "$HANDLER")" = "$before" ] || fail 'dry run modified the handler'
case "$INFOD" in *'would insert'*) ;; *) fail "dry run did not announce the patch: $INFOD" ;; esac

echo 'deploy-proto-handler: ok'
