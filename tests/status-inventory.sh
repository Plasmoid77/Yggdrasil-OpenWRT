#!/bin/sh
# shellcheck disable=SC2034,SC2317,SC2329
# Production functions are extracted verbatim; OpenWrt I/O is supplied by fixtures.
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="${STATUS_SOURCE:-$ROOT/source/yggdrasil-status/root/usr/libexec/rpcd/luci.yggdrasil-status}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [ "$1" = "$2" ] || fail "expected [$1], got [$2]"; }
load() {
    body="$(awk -v name="$1" '
        $0 ~ "^" name "\\(\\)" { found=1 }
        found { print }
        found && /^}/ { exit }
    ' "$SOURCE")"
    [ -n "$body" ] || fail "production function missing: $1"
    eval "$body"
}
for fn in lower normalize_mac valid_mac valid_hostname valid_ipv4 first_ipv4 \
    lease_is_active mac_was_emitted remember_emitted_mac find_active_lease_by_mac \
    eui64_ipv6_for_mac append_unique_ipv6 observed_ipv6_for_mac build_known_ipv6 \
    neighbor_recently_reachable probe_online emit_dynamic_leases emit_persistent_host \
    emit_client rpc_pin rpc_unpin; do load "$fn"; done
COUNT=0
run() {
    COUNT=$((COUNT + 1))
    ( "$2" ) || fail "$1"
    printf 'PASS: %s\n' "$1"
}

lease_lifetime() {
    NOW=100
    lease_is_active 101 || fail 'future lease rejected'
    lease_is_active 0 || fail 'unlimited lease rejected'
    if lease_is_active 100; then fail 'expiry boundary retained'; fi
    if lease_is_active 99; then fail 'expired lease retained'; fi
    if lease_is_active invalid; then fail 'invalid expiry retained'; fi
}

ipv6_selection() {
    LAN_YGG_PREFIX='300:1111:2222:3333:'
    LAN_DEV=br-lan
    MAC='aa:bb:cc:dd:ee:ff'
    STABLE='300:1111:2222:3333:a8bb:ccff:fedd:eeff'
    PRIVACY='300:1111:2222:3333:1234:5678:abcd:9999'
    CANONICAL_IPV6='300:1111:2222:3333::5'
    ip() { printf '%s\n' "$NEIGHBORS"; }
    NEIGHBORS="$STABLE lladdr $MAC router STALE
$PRIVACY lladdr $MAC REACHABLE
$PRIVACY lladdr $MAC STALE
200:1111:2222:3333::1 lladdr $MAC REACHABLE
300:1111:2222:3333::9 lladdr 11:22:33:44:55:66 REACHABLE"
    build_known_ipv6 "$MAC"
    eq "$CANONICAL_IPV6" "$KNOWN_IPV6"
    CANONICAL_IPV6=''
    build_known_ipv6 "$MAC"
    eq "$STABLE" "$KNOWN_IPV6"
    NEIGHBORS="$PRIVACY lladdr $MAC router STALE
$PRIVACY lladdr $MAC REACHABLE
300:1111:2222:3333::8 lladdr $MAC FAILED"
    build_known_ipv6 "$MAC"
    eq "$PRIVACY 300:1111:2222:3333::8" "$KNOWN_IPV6"
    NEIGHBORS=''
    build_known_ipv6 "$MAC"
    eq '' "$KNOWN_IPV6"
}

presence() {
    LAN_DEV=br-lan
    KNOWN_IPV6='300:1111:2222:3333::5'
    TRACE="$TMP/probes"
    : > "$TRACE"
    STATE=REACHABLE
    ARP_OK=1
    PING_OK=1
    ip() { printf 'address lladdr aa:bb:cc:dd:ee:ff %s\n' "$STATE"; }
    arping() { echo arp >> "$TRACE"; return "$ARP_OK"; }
    ping() { echo ping >> "$TRACE"; return "$PING_OK"; }
    probe_online 192.0.2.1 || fail 'recent REACHABLE not online'
    eq '' "$(cat "$TRACE")"
    STATE=STALE
    ARP_OK=0
    probe_online 192.0.2.1 || fail 'ARP success not online'
    eq arp "$(cat "$TRACE")"
    : > "$TRACE"
    STATE=FAILED
    ARP_OK=1
    PING_OK=0
    probe_online 192.0.2.1 || fail 'IPv6 success not online'
    eq "$(printf 'arp\nping')" "$(cat "$TRACE")"
    PING_OK=1
    if probe_online 192.0.2.1; then fail 'failed probes marked online'; fi
}

identity_lifetime() {
    NOW=100
    LEASE_FILE="$TMP/leases"
    cat > "$LEASE_FILE" <<'LEASES'
200 aa:bb:cc:dd:ee:ff 192.0.2.1 dynamic *
200 AA:BB:CC:DD:EE:FF 192.0.2.1 duplicate *
99 11:22:33:44:55:66 192.0.2.2 expired *
200 22:33:44:55:66:77 192.0.2.3 guest *
LEASES
    EMITTED_MACS=''
    find_host_by_mac() {
        case "$(normalize_mac "$1")" in
            aa:bb:cc:dd:ee:ff|33:44:55:66:77:88)
                FOUND_HOST_NAME=Persistent
                FOUND_HOST_STATIC_IPV4=192.0.2.10
                FOUND_HOST_MANAGED=1
                FOUND_HOST_MAC_COUNT=1
                FOUND_HOST_COMPLEX=0
                FOUND_HOST_AMBIGUOUS=0
                return 0 ;;
            *) return 1 ;;
        esac
    }
    # Capture the real enumerator's output at its serialization boundary.
    emit_client() {
        printf '%s|%s|%s|%s\n' "$1" "$(normalize_mac "$2")" "$3" "$4" >> "$TMP/rows"
        remember_emitted_mac "$2"
    }
    config_get() { eval "$1='33:44:55:66:77:88'"; }
    : > "$TMP/rows"
    emit_dynamic_leases
    emit_persistent_host persistent_no_lease
    eq "$(printf '%s\n' \
        'Persistent|aa:bb:cc:dd:ee:ff|192.0.2.10|1' \
        'guest|22:33:44:55:66:77|192.0.2.3|0' \
        'Persistent|33:44:55:66:77:88|192.0.2.10|1')" "$(cat "$TMP/rows")"
}

canonical_guard() {
    CANONICAL_IPV6=stale
    DNS_ALIAS=stale
    EMITTED_MACS=''
    LOOKED_UP=0
    find_canonical_domain() { LOOKED_UP=1; CANONICAL_IPV6='300:1111:2222:3333::1'; DNS_ALIAS=host.home.arpa; }
    build_known_ipv6() { KNOWN_IPV6="$CANONICAL_IPV6"; }
    probe_online() { return 1; }
    json_add_object() { :; }; json_close_object() { :; }
    json_add_array() { :; }; json_close_array() { :; }
    json_add_string() { :; }; json_add_int() { :; }
    emit_client host aa:bb:cc:dd:ee:ff 192.0.2.1 0 200 '' 0 0 0 0
    eq 0 "$LOOKED_UP"
    eq '' "$CANONICAL_IPV6"
    eq '' "$DNS_ALIAS"
    emit_client host aa:bb:cc:dd:ee:ff 192.0.2.1 1 200 '' 0 0 0 0
    eq 1 "$LOOKED_UP"
    eq host.home.arpa "$DNS_ALIAS"
}

# RPC guard fixtures stop at the UCI boundary: any unexpected mutation fails.
setup_rpc() {
    CODE=''
    read_request() { return 0; }
    json_get_var() {
        case "$2" in
            mac) eval "$1='aa:bb:cc:dd:ee:ff'" ;;
            name) eval "$1='Host'" ;;
            *) eval "$1='false'" ;;
        esac
    }
    json_reply() { CODE="$2"; }
    json_reply_device() { CODE="$2"; }
    acquire_dhcp_lock() { return 0; }
    config_load() { :; }
    uci() { fail 'protected RPC reached UCI mutation'; }
    backup_dhcp_config() { fail 'protected RPC reached backup/mutation'; }
    PIN_SECTION_PREFIX=ygg_status_
    FOUND_HOST_MATCH_COUNT=1
    FOUND_HOST_MAC_COUNT=1
    FOUND_HOST_COMPLEX=0
    FOUND_HOST_STATIC_IPV4=''
    FOUND_HOST_NAME=Host
    FOUND_HOST_SELECTOR=host_fixture
    find_host_by_mac() { return 0; }
    dhcp_has_pending_changes() { return 1; }
}
unpin_guards() {
    setup_rpc
    FOUND_HOST_MATCH_COUNT=2
    rpc_unpin
    eq ambiguous_host "$CODE"
    FOUND_HOST_MATCH_COUNT=1
    FOUND_HOST_MAC_COUNT=2
    rpc_unpin
    eq shared_host "$CODE"
    FOUND_HOST_MAC_COUNT=1
    FOUND_HOST_COMPLEX=1
    rpc_unpin
    eq complex_host "$CODE"
    FOUND_HOST_COMPLEX=0
    FOUND_HOST_STATIC_IPV4=192.0.2.1
    rpc_unpin
    eq static_confirmation_required "$CODE"
    FOUND_HOST_STATIC_IPV4=''
    dhcp_has_pending_changes() { return 0; }
    rpc_unpin
    eq pending_uci_changes "$CODE"
    acquire_dhcp_lock() { return 1; }
    rpc_unpin
    eq busy "$CODE"
}
pin_guards() {
    setup_rpc
    rpc_pin
    eq already_persistent "$CODE"
    find_host_by_mac() { return 1; }
    find_active_lease_by_mac() { return 1; }
    rpc_pin
    eq no_active_lease "$CODE"
    find_active_lease_by_mac() { LEASE_MATCH_NAME=Host; LEASE_MATCH_IPV4=192.0.2.1; return 0; }
    dhcp_has_pending_changes() { return 0; }
    rpc_pin
    eq pending_uci_changes "$CODE"
    acquire_dhcp_lock() { return 1; }
    rpc_pin
    eq busy "$CODE"
}

run 'DHCP expiry boundary and unlimited leases' lease_lifetime
run 'canonical, observed EUI-64, privacy and foreign-prefix selection' ipv6_selection
run 'REACHABLE shortcut, ARP, IPv6 and failed presence' presence
run 'DHCP lifetime, MAC merge and persistent lease-free rows' identity_lifetime
run 'dynamic hostnames cannot inherit canonical metadata' canonical_guard
run 'Unpin destructive and pending-change guards' unpin_guards
run 'Pin existing, expired, pending-change and busy guards' pin_guards
printf '%s backend fixture groups passed\n' "$COUNT"
