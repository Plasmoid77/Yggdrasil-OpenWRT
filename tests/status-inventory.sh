#!/bin/sh
# shellcheck disable=SC2012,SC2034,SC2317,SC2329
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
    lease_is_active mac_was_emitted remember_emitted_mac remember_persistent_mac \
    find_active_lease_by_mac \
    eui64_ipv6_for_mac append_unique_ipv6 observed_ipv6_for_mac build_known_ipv6 \
    neighbor_recently_reachable probe_online emit_dynamic_leases emit_persistent_host \
    mac_for_neighbor ygg_peer_endpoints ygg_node_rows ygg_node_addresses_for_mac \
    merge_node_cache write_node_memory save_node_cache ygg_node_is_live \
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

# A LAN device running its own daemon peers with the router. Only an established
# link whose transport endpoint is a literal address on this LAN can be
# attributed to a client row.
ygg_node_map() {
    LAN_DEV=br-lan
    YGG_NET=ygg0
    LAN_PEER='fe80::5839:1d8e:ec3b:eea8'
    NODE='200:f2ca:2ec4:9077:ed8b:b013:228d:75d0'
    PEERS='{ "remote": "tls:\/\/ygg-msk-1.example.net:8362", "up": true, "address": "20a:5fad::e155:42:290b:d6b5" }
{ "remote": "tls:\/\/['"$LAN_PEER"'%25br-lan]:39767", "up": true, "inbound": false, "address": "'"$NODE"'" }
{ "remote": "tls:\/\/['"$LAN_PEER"'%25br-lan]:42041", "up": true, "inbound": true, "address": "200:F2CA:2EC4:9077:ED8B:B013:228D:75D0" }
{ "remote": "tls:\/\/[fe80::dead:beef%25wg0]:1234", "up": true, "address": "201:aaaa::1" }
{ "remote": "tcp:\/\/192.168.1.50:9001", "up": true, "address": "203:bbbb::2" }
{ "remote": "tcp:\/\/192.168.1.77:9001", "up": true, "address": "205:eeee::5" }
{ "remote": "tls:\/\/['"$LAN_PEER"'%25br-lan]:5000", "up": false, "address": "204:cccc::3" }'
    # The production pipeline is yggdrasilctl | jsonfilter | awk.
    yggdrasilctl() { printf '%s\n' "$PEERS"; }
    jsonfilter() { cat; }
    ip() {
        case "$*" in
            *"to $LAN_PEER dev"*) echo "$LAN_PEER lladdr 14:4F:8A:8D:19:77 router STALE" ;;
            *'to 192.168.1.50 dev'*) echo '192.168.1.50 dev br-lan lladdr aa:bb:cc:dd:ee:01 REACHABLE' ;;
            *) : ;;
        esac
    }
    eq "$(printf '%s\n' \
        "$LAN_PEER $NODE" \
        "$LAN_PEER $NODE" \
        '192.168.1.50 203:bbbb::2' \
        '192.168.1.77 205:eeee::5')" "$(ygg_peer_endpoints)"
    YGG_NODE_ROWS="$(ygg_node_rows)"
    eq "$(printf '%s\n' \
        "14:4f:8a:8d:19:77 $NODE 1" \
        'aa:bb:cc:dd:ee:01 203:bbbb::2 1')" "$YGG_NODE_ROWS"
    eq "$NODE" "$(ygg_node_addresses_for_mac 14:4F:8A:8D:19:77)"
    eq '' "$(ygg_node_addresses_for_mac 2a:32:f9:81:71:23)"
    YGG_NODE_ROWS=''
    eq '' "$(ygg_node_addresses_for_mac 14:4f:8a:8d:19:77)"

    # An upstream rename must degrade to shape matching, not to an empty column.
    PEERS='{ "endpoint": "tls:\/\/['"$LAN_PEER"'%25br-lan]:39767", "up": true, "ip": "'"$NODE"'" }'
    eq "$LAN_PEER $NODE" "$(ygg_peer_endpoints)"
    PEERS='{ "somethingelse": "tls:\/\/['"$LAN_PEER"'%25br-lan]:39767", "up": true, "whatever": "'"$NODE"'", "key": "9648f51ce4bcd53700bf21a8a2878703f6e05ce7133ce89a770f79e667d0256c", "last_error": "read tcp 10.0.0.1:1-\u003e10.0.0.2:2: i\/o timeout" }'
    eq "$LAN_PEER $NODE" "$(ygg_peer_endpoints)"
}

# A remembered address survives exactly as long as the row it belongs to.
node_memory() {
    NODE_CACHE_FILE="$TMP/nodes"
    NODE_STORE_FILE="$TMP/nodes.flash"
    PERSISTENT_MACS=''
    NODE='200:f2ca:2ec4:9077:ed8b:b013:228d:75d0'
    MAC='14:4f:8a:8d:19:77'
    GONE='aa:bb:cc:dd:ee:01'

    # First pass: two peering devices are observed live and remembered.
    YGG_NODE_ROWS="$(printf '%s\n' "$MAC $NODE 1" "$GONE 203:bbbb::2 1")"
    merge_node_cache
    EMITTED_MACS="|$MAC||$GONE|"
    save_node_cache
    eq "$(printf '%s\n' "$MAC $NODE" "$GONE 203:bbbb::2")" "$(cat "$NODE_CACHE_FILE")"

    # Second pass: neither device is peering, both rows still exist.
    YGG_NODE_ROWS=''
    merge_node_cache
    eq "$(printf '%s\n' "$MAC $NODE 0" "$GONE 203:bbbb::2 0")" "$YGG_NODE_ROWS"
    eq "$NODE" "$(ygg_node_addresses_for_mac "$MAC")"
    if ygg_node_is_live "$MAC"; then fail 'remembered address reported as live'; fi

    # The row for one device disappears; its memory is pruned with it.
    EMITTED_MACS="|$MAC|"
    save_node_cache
    eq "$MAC $NODE" "$(cat "$NODE_CACHE_FILE")"

    # A fresh observation replaces everything remembered for that MAC.
    YGG_NODE_ROWS="$MAC 200:aaaa::9 1"
    merge_node_cache
    eq "$MAC 200:aaaa::9 1" "$YGG_NODE_ROWS"
    eq '200:aaaa::9' "$(ygg_node_addresses_for_mac "$MAC")"
    ygg_node_is_live "$MAC" || fail 'fresh observation not reported as live'
    save_node_cache
    eq "$MAC 200:aaaa::9" "$(cat "$NODE_CACHE_FILE")"

    # A missing cache file is an empty memory, not an error.
    rm -f "$NODE_CACHE_FILE"
    YGG_NODE_ROWS=''
    merge_node_cache
    eq '' "$YGG_NODE_ROWS"
}

# A pinned row lives on flash, so its remembered address must too: it has to
# come back after a reboot wipes tmpfs, and go away when the pin does.
pinned_node_memory() {
    NODE_CACHE_FILE="$TMP/pin-nodes"
    NODE_STORE_FILE="$TMP/pin-nodes.flash"
    PINNED='14:4f:8a:8d:19:77'
    LEASED='aa:bb:cc:dd:ee:02'
    NODE='200:f2ca:2ec4:9077:ed8b:b013:228d:75d0'

    # Both devices peer; only the pinned one reaches the flash memory.
    YGG_NODE_ROWS="$(printf '%s\n' "$PINNED $NODE 1" "$LEASED 200:cccc::3 1")"
    merge_node_cache
    EMITTED_MACS="|$PINNED||$LEASED|"
    PERSISTENT_MACS="|$PINNED|"
    save_node_cache
    eq "$(printf '%s\n' "$PINNED $NODE" "$LEASED 200:cccc::3")" "$(cat "$NODE_CACHE_FILE")"
    eq "$PINNED $NODE" "$(cat "$NODE_STORE_FILE")"

    # An unchanged run must not rewrite flash: the file is replaced by rename,
    # so an unchanged inode proves no write happened.
    INODE="$(ls -i "$NODE_STORE_FILE" | awk '{print $1}')"
    merge_node_cache
    save_node_cache
    eq "$INODE" "$(ls -i "$NODE_STORE_FILE" | awk '{print $1}')"

    # Reboot: tmpfs is gone, the daemon has not seen any peer yet. The pinned
    # row recovers its address; the lease-backed row is forgotten, as intended.
    rm -f "$NODE_CACHE_FILE"
    YGG_NODE_ROWS=''
    merge_node_cache
    eq "$PINNED $NODE 0" "$YGG_NODE_ROWS"
    eq "$NODE" "$(ygg_node_addresses_for_mac "$PINNED")"
    if ygg_node_is_live "$PINNED"; then fail 'recalled address reported as live'; fi
    eq '' "$(ygg_node_addresses_for_mac "$LEASED")"

    # The recalled address is written straight back to both memories.
    EMITTED_MACS="|$PINNED|"
    save_node_cache
    eq "$PINNED $NODE" "$(cat "$NODE_CACHE_FILE")"

    # A live observation still wins over the flash memory.
    YGG_NODE_ROWS="$PINNED 200:aaaa::9 1"
    merge_node_cache
    eq "$PINNED 200:aaaa::9 1" "$YGG_NODE_ROWS"
    save_node_cache
    eq "$PINNED 200:aaaa::9" "$(cat "$NODE_STORE_FILE")"

    # Unpin: the MAC stops being persistent, so flash forgets it while the
    # tmpfs memory keeps it for the remaining lease-backed row.
    PERSISTENT_MACS=''
    save_node_cache
    eq '' "$(cat "$NODE_STORE_FILE")"
    eq "$PINNED 200:aaaa::9" "$(cat "$NODE_CACHE_FILE")"
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
    YGG_NODE_ROWS=''
    ygg_node_is_live() { return 1; }
    CANONICAL_IPV6=stale
    DNS_ALIAS=stale
    EMITTED_MACS=''
    PERSISTENT_MACS=''
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
    eq '' "$PERSISTENT_MACS"
    emit_client host aa:bb:cc:dd:ee:ff 192.0.2.1 1 200 '' 0 0 0 0
    eq 1 "$LOOKED_UP"
    eq host.home.arpa "$DNS_ALIAS"
    eq '|aa:bb:cc:dd:ee:ff|' "$PERSISTENT_MACS"
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
run 'LAN Yggdrasil node addresses correlated by MAC' ygg_node_map
run 'remembered node addresses live and die with their row' node_memory
run 'a pinned row keeps its node address across a reboot' pinned_node_memory
run 'REACHABLE shortcut, ARP, IPv6 and failed presence' presence
run 'DHCP lifetime, MAC merge and persistent lease-free rows' identity_lifetime
run 'dynamic hostnames cannot inherit canonical metadata' canonical_guard
run 'Unpin destructive and pending-change guards' unpin_guards
run 'Pin existing, expired, pending-change and busy guards' pin_guards
printf '%s backend fixture groups passed\n' "$COUNT"
