#!/bin/sh
# shellcheck disable=SC2034,SC2317,SC2329,SC2016
# install_hotplug_guard writes /etc/hotplug.d/net/50-yggdrasil-pending: on the
# TUN device's hotplug "add", restart the interface if it is still pending ten
# seconds later (cold-boot race in the stock proto handler). The functions are
# extracted from the deployer and pointed at a fixture path. SC2016: the
# expected lines are literal guard text.

set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/deploy/deploy-openwrt-yggdrasil.sh"
TMP="$(mktemp -d /tmp/ygg-hotplug-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

extract_function() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\)" { found = 1 }
        found { print }
        found && /^}$/ { exit }
    ' "$SCRIPT"
}
for f in hotplug_guard_text install_hotplug_guard; do
    body="$(extract_function "$f")"
    [ -n "$body" ] || { echo "FAIL: function $f not found in deployer" >&2; exit 1; }
    eval "$body"
done
HOTPLUG_FILE="$TMP/hotplug.d/net/50-yggdrasil-pending"

DIED=''; OKD=''; INFOD=''
die()  { DIED="${DIED}${*}
"; }
ok()   { OKD="${OKD}${*}
"; }
info() { INFOD="${INFOD}${*}
"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
reset() { DIED=''; OKD=''; INFOD=''; DRY_RUN=0; IFACE='ygg0'; FAILED_STAGE=''; }

# 1. Written, parses, carries the interface name and nothing unexpanded.
reset
install_hotplug_guard
[ -z "$DIED" ] || fail "unexpected die: $DIED"
[ -f "$HOTPLUG_FILE" ] || fail 'guard not written'
sh -n "$HOTPLUG_FILE" || fail 'guard does not parse'
busybox ash -n "$HOTPLUG_FILE" || fail 'guard does not parse under BusyBox ash'
grep -q '^\[ "\$ACTION" = add \] && \[ "\$DEVICENAME" = '"'"'ygg0'"'"' \] || exit 0$' "$HOTPLUG_FILE" \
    || fail 'event filter line differs'
grep -q "^ifindex=\"\$(cat '/sys/class/net/ygg0/ifindex' 2>/dev/null)\" || exit 0$" "$HOTPLUG_FILE" \
    || fail 'ifindex capture line differs'
grep -q "^	\[ \"\$(ifstatus 'ygg0' | jsonfilter -e '@.pending')\" = true \] || exit 0$" "$HOTPLUG_FILE" \
    || fail 'pending check line differs'
grep -q "^	ubus call 'network.interface.ygg0' down && ubus call 'network.interface.ygg0' up \\\\$" "$HOTPLUG_FILE" \
    || fail 'restart line differs (must be ubus down/up, not ifup)'
grep -q "^	n=\"\$(cat '/tmp/yggdrasil-hotplug.ygg0' 2>/dev/null || echo 0)\"$" "$HOTPLUG_FILE" \
    || fail 'retry counter line differs'
grep -q '^	\[ "\$n" -lt 5 \] || { logger' "$HOTPLUG_FILE" || fail 'retry bound missing'
grep -q '^	sleep 10$' "$HOTPLUG_FILE" || fail 'ten-second wait missing'
grep -q '^	logger -t yggdrasil-hotplug "ygg0 still pending' "$HOTPLUG_FILE" || fail 'restart is not logged'
! grep -q 'IFACE' "$HOTPLUG_FILE" || fail 'unexpanded $IFACE in the guard'
case "$OKD" in *'hotplug guard written'*) ;; *) fail "write not reported: $OKD" ;; esac

# 2. Rerun is a no-op and says so.
before="$(cat "$HOTPLUG_FILE")"; reset
install_hotplug_guard
[ "$(cat "$HOTPLUG_FILE")" = "$before" ] || fail 'rerun changed the guard'
case "$OKD" in *'already in place'*) ;; *) fail "rerun did not report the existing guard: $OKD" ;; esac

# 3. Another interface name is substituted everywhere.
reset; IFACE='ygg'; rm -f "$HOTPLUG_FILE"
install_hotplug_guard
[ "$(grep -c "'ygg0'" "$HOTPLUG_FILE")" = 0 ] || fail 'old interface name left in the guard'
grep -q "network.interface.ygg' down" "$HOTPLUG_FILE" || fail 'interface name not substituted'

# 4. Dry run writes nothing.
reset; rm -f "$HOTPLUG_FILE"; DRY_RUN=1
install_hotplug_guard
[ ! -e "$HOTPLUG_FILE" ] || fail 'dry run wrote the guard'
case "$INFOD" in *'would write'*) ;; *) fail "dry run did not announce the guard: $INFOD" ;; esac

# 5. The guard's own logic, run with stubs: no action when the interface is up,
#    no action when the device was recreated, a restart when still pending.
reset; install_hotplug_guard
STUBS="$TMP/bin"; mkdir -p "$STUBS"; LOG="$TMP/calls"; : > "$LOG"
cat > "$STUBS/ifstatus" <<'STUB'
#!/bin/sh
printf '{ "up": %s, "pending": %s }\n' "$UP" "$PENDING"
STUB
cat > "$STUBS/jsonfilter" <<'STUB'
#!/bin/sh
# only '@.pending' is asked for
sed 's/.*"pending": \([a-z]*\).*/\1/'
STUB
cat > "$STUBS/ubus" <<'STUB'
#!/bin/sh
echo "ubus $*" >> "$LOG"
STUB
# logger is not stubbed: BusyBox sh would run its own applet anyway, and the
# real one only writes a line to syslog. Its presence is checked in the text.
chmod 755 "$STUBS"/*
GUARD="$TMP/guard-under-test"
# The guard reads the ifindex from sysfs; point it at a file we control, and
# do not wait: a stub for sleep would not do, BusyBox sh runs its applets
# without consulting PATH.
sed "s|/sys/class/net/ygg0/ifindex|$TMP/ifindex|g; s|/tmp/yggdrasil-hotplug.ygg0|$TMP/retries|g; s|^	sleep 10$|	sleep 0|" "$HOTPLUG_FILE" > "$GUARD"
grep -q '^	sleep 0$' "$GUARD" || fail 'could not neutralise the wait in the guard under test' 
run_guard() { # $1 = up, $2 = pending
    : > "$LOG"
    ACTION=add DEVICENAME=ygg0 UP="$1" PENDING="$2" LOG="$LOG" PATH="$STUBS:$PATH" sh "$GUARD"
    wait 2>/dev/null || true
    sleep 1
}
echo 7 > "$TMP/ifindex"
run_guard true false
[ ! -s "$LOG" ] || fail "guard acted on a healthy interface: $(cat "$LOG")"
run_guard false true
grep -q "ubus call 'network.interface.ygg0' down" "$LOG" 2>/dev/null \
    || grep -q 'ubus call network.interface.ygg0 down' "$LOG" \
    || fail "guard did not restart a pending interface: $(cat "$LOG")"
grep -q 'network.interface.ygg0 up' "$LOG" || fail 'guard did not bring the interface up again'
: > "$LOG"
ACTION=remove DEVICENAME=ygg0 UP=false PENDING=true LOG="$LOG" PATH="$STUBS:$PATH" sh "$GUARD"; sleep 1
[ ! -s "$LOG" ] || fail 'guard acted on a remove event'
: > "$LOG"
ACTION=add DEVICENAME=eth0 UP=false PENDING=true LOG="$LOG" PATH="$STUBS:$PATH" sh "$GUARD"; sleep 1
[ ! -s "$LOG" ] || fail 'guard acted on another device'
[ "$(cat "$TMP/retries")" = 1 ] || fail "retry counter not 1 after one restart: $(cat "$TMP/retries" 2>/dev/null)"
echo 5 > "$TMP/retries"
run_guard false true
! grep -q 'ubus' "$LOG" || fail 'guard restarted beyond the five-per-boot bound'
[ "$(cat "$TMP/retries")" = 5 ] || fail 'counter changed after giving up'
rm -f "$TMP/retries"
rm -f "$TMP/ifindex"
: > "$LOG"
ACTION=add DEVICENAME=ygg0 UP=false PENDING=true LOG="$LOG" PATH="$STUBS:$PATH" sh "$GUARD"; sleep 1
[ ! -s "$LOG" ] || fail 'guard acted although the device is gone'

echo 'deploy-hotplug-guard: ok'
