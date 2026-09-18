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
    merge_node_cache write_address_memory save_address_memory ygg_node_is_live \
    recall_lan_addresses remember_lan_addresses \
    discover_lan_addresses confirm_discovered_addresses \
    collect_host_duids collect_host_duid host_mac_for_duid mac_seen_on_lan mac_for_lease collect_dhcpv6_leases probe_unattributed_leases dhcpv6_lease_for_mac dhcpv6_lease_match_for_mac \
    norm_hostid valid_hostid collect_taken_hostids collect_taken_hostid lease_duid_for_mac emit_dynamic_leases6 \
    iid_to_addr find_active_lease6_by_mac \
    emit_client rpc_pin rpc_unpin; do load "$fn"; done

# The production constants point at /tmp and /etc. Default every memory into
# the sandbox so no group can touch a real path by forgetting to override one.
NODE_CACHE_FILE="$TMP/default-nodes"
NODE_STORE_FILE="$TMP/default-nodes.flash"
LAN_CACHE_FILE="$TMP/default-lan"
LAN_STORE_FILE="$TMP/default-lan.flash"
LAN_ADDR_ROWS=''
LAN_YGG_PREFIX=''
LAN_NET='lan'
uci() { return 1; }
DISCOVERY_WANTED=0
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
    save_address_memory
    eq "$(printf '%s\n' "$MAC $NODE" "$GONE 203:bbbb::2")" "$(cat "$NODE_CACHE_FILE")"

    # Second pass: neither device is peering, both rows still exist.
    YGG_NODE_ROWS=''
    merge_node_cache
    eq "$(printf '%s\n' "$MAC $NODE 0" "$GONE 203:bbbb::2 0")" "$YGG_NODE_ROWS"
    eq "$NODE" "$(ygg_node_addresses_for_mac "$MAC")"
    if ygg_node_is_live "$MAC"; then fail 'remembered address reported as live'; fi

    # The row for one device disappears; its memory is pruned with it.
    EMITTED_MACS="|$MAC|"
    save_address_memory
    eq "$MAC $NODE" "$(cat "$NODE_CACHE_FILE")"

    # A fresh observation replaces everything remembered for that MAC.
    YGG_NODE_ROWS="$MAC 200:aaaa::9 1"
    merge_node_cache
    eq "$MAC 200:aaaa::9 1" "$YGG_NODE_ROWS"
    eq '200:aaaa::9' "$(ygg_node_addresses_for_mac "$MAC")"
    ygg_node_is_live "$MAC" || fail 'fresh observation not reported as live'
    save_address_memory
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
    save_address_memory
    eq "$(printf '%s\n' "$PINNED $NODE" "$LEASED 200:cccc::3")" "$(cat "$NODE_CACHE_FILE")"
    eq "$PINNED $NODE" "$(cat "$NODE_STORE_FILE")"

    # An unchanged run must not rewrite flash: the file is replaced by rename,
    # so an unchanged inode proves no write happened.
    INODE="$(ls -i "$NODE_STORE_FILE" | awk '{print $1}')"
    merge_node_cache
    save_address_memory
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
    save_address_memory
    eq "$PINNED $NODE" "$(cat "$NODE_CACHE_FILE")"

    # A live observation still wins over the flash memory.
    YGG_NODE_ROWS="$PINNED 200:aaaa::9 1"
    merge_node_cache
    eq "$PINNED 200:aaaa::9 1" "$YGG_NODE_ROWS"
    save_address_memory
    eq "$PINNED 200:aaaa::9" "$(cat "$NODE_STORE_FILE")"

    # Unpin: the MAC stops being persistent, so flash forgets it while the
    # tmpfs memory keeps it for the remaining lease-backed row.
    PERSISTENT_MACS=''
    save_address_memory
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

# odhcpd's bound leases are the router's own record of the addresses it handed
# out. A lease is attributed to a row through the MAC inside a DUID-LLT or
# DUID-LL, exactly the way odhcpd itself matches a config host by MAC; other
# DUID types carry no MAC and attribute nothing. In a row the lease comes first,
# observed addresses follow, a canonical record still wins.
dhcpv6_lease_source() {
    LAN_YGG_PREFIX='300:1111:2222:3333:'
    LAN_DEV=br-lan
    MAC='aa:bb:cc:dd:ee:ff'
    LEASE_LLT='{"duid":"00010001323A02A7AABBCCDDEEFF","hostname":"zeonux","flags":["bound"],"ipv6-addr":[{"address":"300:1111:2222:3333::10"}]}'
    LEASE_LL='{"duid":"00030001112233445566","flags":["bound"],"ipv6-addr":[{"address":"300:1111:2222:3333::20"},{"address":"2001:db8::20"}]}'
    LEASE_ZERO='{"duid":"00030001000000000000","flags":["bound"],"ipv6-addr":[{"address":"300:1111:2222:3333::32d"}]}'
    LEASE_UUID='{"duid":"00040001000000000000000000000000","flags":["bound"],"ipv6-addr":[{"address":"300:1111:2222:3333::40"}]}'
    LEASE_OFFER='{"duid":"00010001323A02A7112233445577","flags":[],"ipv6-addr":[{"address":"300:1111:2222:3333::50"}]}'
    # a DUID-UUID laptop on cable and Wi-Fi: one DUID, two IAIDs, config host per interface
    LEASE_UUID_ETH='{"duid":"0004ECBCBFB80EF2996849BCA6B0D0A6FFCE","iaid":544072138,"flags":["bound"],"ipv6-addr":[{"address":"300:1111:2222:3333::20"}]}'
    LEASE_UUID_WLAN='{"duid":"0004ECBCBFB80EF2996849BCA6B0D0A6FFCE","iaid":-765884849,"flags":["bound"],"ipv6-addr":[{"address":"300:1111:2222:3333::21"}]}'
    ubus() { echo '{"device":{"br-lan":{"leases":[]}}}'; }
    jsonfilter() {
        case "$*" in
            *'@.device[*].leases[*]'*) printf '%s\n' "$LEASE_LLT" "$LEASE_LL" "$LEASE_ZERO" "$LEASE_UUID" "$LEASE_OFFER" "$LEASE_UUID_ETH" "$LEASE_UUID_WLAN" ;;
            *'@.flags'*) tr ',' '\n' | sed -n 's/.*"flags":\["\([^"]*\)".*/\1/p' ;;
            *'@.iaid'*) sed -n 's/.*"iaid":\(-\{0,1\}[0-9]*\).*/\1/p' ;;
            *'@.hostname'*) sed -n 's/.*"hostname":"\([^"]*\)".*/\1/p' ;;
            *'@.duid'*) sed -n 's/.*"duid":"\([^"]*\)".*/\1/p' ;;
            *'ipv6-addr'*) tr ',' '\n' | sed -n 's/.*"address":"\([^"]*\)".*/\1/p' ;;
            *) cat ;;
        esac
    }
    # config host: the wired port by DUID%IAID, the Wi-Fi port by DUID%IAID, and a
    # DUID-only section that would cover any other interface of that machine
    CONFIG_HOSTS='eth|0004ecbcbfb80ef2996849bca6b0d0a6ffce%206de1ca|3c:e1:a1:41:52:d0
wlan|0004ECBCBFB80EF2996849BCA6B0D0A6FFCE%D259864F|14:4F:8A:8D:19:77
any|0004ecbcbfb80ef2996849bca6b0d0a6ffce|00:11:22:33:44:55
nomac|00030001000000000000|'
    config_get() {
        case "$3" in
            duid) eval "$1=\"$(printf '%s\n' "$CONFIG_HOSTS" | awk -F'|' -v s="$2" '$1 == s { print $2 }')\"" ;;
            mac)  eval "$1=\"$(printf '%s\n' "$CONFIG_HOSTS" | awk -F'|' -v s="$2" '$1 == s { print $3 }')\"" ;;
        esac
    }
    HOST_DUID_MACS=''
    for sec in eth wlan any nomac; do collect_host_duid "$sec"; done
    eq "$(printf '%s\n' \
        '0004ecbcbfb80ef2996849bca6b0d0a6ffce%206de1ca 3c:e1:a1:41:52:d0' \
        '0004ecbcbfb80ef2996849bca6b0d0a6ffce%d259864f 14:4f:8a:8d:19:77' \
        '0004ecbcbfb80ef2996849bca6b0d0a6ffce 00:11:22:33:44:55')" "$HOST_DUID_MACS"
    eq '3c:e1:a1:41:52:d0' "$(host_mac_for_duid 0004ecbcbfb80ef2996849bca6b0d0a6ffce 206de1ca)"
    eq '00:11:22:33:44:55' "$(host_mac_for_duid 0004ecbcbfb80ef2996849bca6b0d0a6ffce 1)"
    eq '' "$(host_mac_for_duid 00030001000000000000 2b67)"
    # a generic entry listed before the exact one must not yield two MACs
    HOST_DUID_MACS="$(printf '%s\n' '0004ecbc00 aa:aa:aa:aa:aa:aa' '0004ecbc00%2 bb:bb:bb:bb:bb:bb')"
    eq 'bb:bb:bb:bb:bb:bb' "$(host_mac_for_duid 0004ecbc00 2)"
    eq 'aa:aa:aa:aa:aa:aa' "$(host_mac_for_duid 0004ecbc00 3)"
    # all-digit DUIDs are strings, not numbers
    HOST_DUID_MACS='00030001000000000001 cc:cc:cc:cc:cc:cc'
    eq '' "$(host_mac_for_duid 30001000000000001 1)"
    eq 'cc:cc:cc:cc:cc:cc' "$(host_mac_for_duid 00030001000000000001 1)"
    HOST_DUID_MACS=''
    for sec in eth wlan any nomac; do collect_host_duid "$sec"; done
    # a reserved suffix renders as a real address, whatever its width
    eq '300:1111:2222:3333::10' "$(iid_to_addr '300:1111:2222:3333:' 10)"
    eq '300:1111:2222:3333::1:0' "$(iid_to_addr '300:1111:2222:3333:' 10000)"
    eq '300:1111:2222:3333:abcd:ef01:2345:6789' "$(iid_to_addr '300:1111:2222:3333:' abcdef0123456789)"
    eq '300:1111:2222:3333:1000::' "$(iid_to_addr '300:1111:2222:3333:' 1000000000000000)"
    # no neighbour table here: the DUID-UUID lease with no config host stays out;
    # the DUID-LLT/LL MACs are on the LAN through their DHCPv4 leases
    LAN_DEV='br-lan'
    ip() { :; }
    LEASE_FILE="$TMP/dhcp.leases"
    NOW=100
    printf '%s\n' '9999999999 aa:bb:cc:dd:ee:ff 192.0.2.10 zeonux *' '0 11:22:33:44:55:66 192.0.2.20 * *' '50 de:ad:be:ef:00:01 192.0.2.30 gone *' > "$LEASE_FILE"
    mac_seen_on_lan aa:bb:cc:dd:ee:ff || fail 'active DHCPv4 lease not counted as LAN evidence'
    mac_seen_on_lan 11:22:33:44:55:66 || fail 'unlimited DHCPv4 lease not counted as LAN evidence'
    if mac_seen_on_lan de:ad:be:ef:00:01; then fail 'expired DHCPv4 lease counted as LAN evidence'; fi
    collect_dhcpv6_leases
    eq "$(printf '%s\n' \
        'aa:bb:cc:dd:ee:ff 300:1111:2222:3333::10 zeonux duid' \
        '11:22:33:44:55:66 300:1111:2222:3333::20 - duid' \
        '3c:e1:a1:41:52:d0 300:1111:2222:3333::20 - host' \
        '14:4f:8a:8d:19:77 300:1111:2222:3333::21 - host')" "$DHCPV6_LEASES"
    eq duid "$(dhcpv6_lease_match_for_mac aa:bb:cc:dd:ee:ff)"
    eq host "$(dhcpv6_lease_match_for_mac 3c:e1:a1:41:52:d0)"
    # the DUID-UUID lease nobody could be tied to is queued for a probe, and
    # the probe reaches exactly those addresses
    eq "$(printf '%s\n' 300:1111:2222:3333::32d 300:1111:2222:3333::40)" "$UNATTRIBUTED_LEASE_ADDRS"
    PINGED="$TMP/pinged"; : > "$PINGED"
    ping() { printf '%s\n' "$*" >> "$PINGED"; }
    probe_unattributed_leases; wait
    grep -q -- '-6 -c 1 -W 1 300:1111:2222:3333::40' "$PINGED" || fail "unattributed lease address not probed: $(cat "$PINGED")"
    UNATTRIBUTED_LEASE_ADDRS=''; : > "$PINGED"; probe_unattributed_leases; wait
    [ ! -s "$PINGED" ] || fail "probe ran with nothing to probe"
    unset -f ping
    # the neighbour table names the DUID-UUID lease when one device answers
    # for its addresses - in any prefix - and nobody when two do
    ip() {
        case "$*" in
            *'300:1111:2222:3333::40 '*) printf '%s\n' '300:1111:2222:3333::40 dev br-lan lladdr 66:77:88:99:aa:bb STALE' ;;
        esac
    }
    collect_dhcpv6_leases
    printf '%s\n' "$DHCPV6_LEASES" | grep -qxF '66:77:88:99:aa:bb 300:1111:2222:3333::40 - neighbor' \
        || fail "DUID-UUID lease not attributed through the neighbour table: $DHCPV6_LEASES"
    LEASE_UUID='{"duid":"00040001000000000000000000000000","flags":["bound"],"ipv6-addr":[{"address":"2001:db8::40"},{"address":"300:1111:2222:3333::40"}]}'
    ip() {
        case "$*" in
            *'2001:db8::40 '*) printf '%s\n' '2001:db8::40 dev br-lan lladdr 66:77:88:99:aa:bb REACHABLE' ;;
        esac
    }
    collect_dhcpv6_leases
    printf '%s\n' "$DHCPV6_LEASES" | grep -qxF '66:77:88:99:aa:bb 300:1111:2222:3333::40 - neighbor' \
        || fail "a neighbour entry for the native address did not attribute the routed one: $DHCPV6_LEASES"
    ip() {
        case "$*" in
            *'2001:db8::40 '*) printf '%s\n' '2001:db8::40 dev br-lan lladdr 66:77:88:99:aa:bb REACHABLE' ;;
            *'300:1111:2222:3333::40 '*) printf '%s\n' '300:1111:2222:3333::40 dev br-lan lladdr 00:de:ad:be:ef:00 STALE' ;;
        esac
    }
    collect_dhcpv6_leases
    printf '%s\n' "$DHCPV6_LEASES" | grep -q '::40 ' && fail "a lease answered by two MACs was attributed: $DHCPV6_LEASES"
    # the MAC inside a DUID-LL/LLT is trusted only with hardware type 1, a
    # non-zero MAC and a MAC the LAN has seen; otherwise the neighbour table decides
    eq '11:22:33:44:55:66 duid' "$(mac_for_lease 00030001112233445566 '')"
    eq '' "$(mac_for_lease 00030006112233445566 '')"
    eq '' "$(mac_for_lease 00030001000000000000 '')"
    eq '' "$(mac_for_lease 0001000612345678112233445566 '')"
    # a Windows DUID-LLT made on another adapter names a MAC the LAN never saw:
    # the neighbour table attributes the lease to the adapter that is here
    eq '' "$(mac_for_lease 000100012c3d9ac708bfb82cb43d '' 300:1111:2222:3333::36a)"
    ip() { case "$*" in *'::36a '*) printf '%s\n' '300:1111:2222:3333::36a dev br-lan lladdr 58:1c:f8:29:fb:08 STALE' ;; esac; }
    eq '58:1c:f8:29:fb:08 neighbor' "$(mac_for_lease 000100012c3d9ac708bfb82cb43d '' 300:1111:2222:3333::36a)"
    # ... and a DUID MAC known only from a neighbour entry still counts
    ip() { printf '%s\n' 'fe80::1 dev br-lan lladdr 08:bf:b8:2c:b4:3d REACHABLE'; }
    eq '08:bf:b8:2c:b4:3d duid' "$(mac_for_lease 000100012c3d9ac708bfb82cb43d '' 300:1111:2222:3333::36a)"
    ip() { printf '%s\n' '300:1111:2222:3333::50 dev br-lan lladdr 0a:0b:0c:0d:0e:0f REACHABLE'; }
    eq '0a:0b:0c:0d:0e:0f neighbor' "$(mac_for_lease 00030006112233445566 '' 300:1111:2222:3333::50)"
    # a config host outranks both
    eq '3c:e1:a1:41:52:d0 host' "$(mac_for_lease 0004ecbcbfb80ef2996849bca6b0d0a6ffce 206de1ca 300:1111:2222:3333::50)"
    LEASE_UUID='{"duid":"00040001000000000000000000000000","flags":["bound"],"ipv6-addr":[{"address":"300:1111:2222:3333::40"}]}'
    ip() { :; }
    collect_dhcpv6_leases
    # an IPv6-only client (no DHCPv4 lease) gets a row from its bound lease,
    # named from the lease, merged by MAC like every other row; one already
    # emitted from DHCPv4 is not duplicated
    ROWS=''
    emit_client() { ROWS="$ROWS|$1/$2/$4"; remember_emitted_mac "$2"; }
    find_host_by_mac() { return 1; }
    EMITTED_MACS='|11:22:33:44:55:66|'
    emit_dynamic_leases6
    eq '|zeonux/aa:bb:cc:dd:ee:ff/0|/3c:e1:a1:41:52:d0/0|/14:4f:8a:8d:19:77/0' "$ROWS"
    find_active_lease6_by_mac aa:bb:cc:dd:ee:ff || fail 'IPv6-only client not found by its lease'
    eq zeonux "$LEASE_MATCH_NAME"
    # a lease known through the neighbour table alone names a row but does
    # not make the client pinnable
    saved_leases="$DHCPV6_LEASES"
    DHCPV6_LEASES='66:77:88:99:aa:bb 300:1111:2222:3333::40 - neighbor'
    if find_active_lease6_by_mac 66:77:88:99:aa:bb; then fail 'neighbour-attributed lease accepted as Pin evidence'; fi
    DHCPV6_LEASES="$saved_leases"
    # Pin records a DUID on a neighbour match only while the entry is REACHABLE
    HOST_DUID_MACS=''
    ip() { case "$*" in *'::40 '*) printf '%s\n' '300:1111:2222:3333::40 dev br-lan lladdr 66:77:88:99:aa:bb STALE' ;; esac; }
    eq '' "$(lease_duid_for_mac 66:77:88:99:aa:bb)"
    ip() { case "$*" in *'::40 '*) printf '%s\n' '300:1111:2222:3333::40 dev br-lan lladdr 66:77:88:99:aa:bb REACHABLE' ;; esac; }
    eq '00040001000000000000000000000000' "$(lease_duid_for_mac 66:77:88:99:aa:bb)"
    # ... while a config host or DUID-LL match needs no neighbour at all
    ip() { :; }
    eq '00030001112233445566' "$(lease_duid_for_mac 11:22:33:44:55:66)"
    for sec in eth wlan any nomac; do collect_host_duid "$sec"; done
    eq '0004ecbcbfb80ef2996849bca6b0d0a6ffce%206de1ca' "$(lease_duid_for_mac 3c:e1:a1:41:52:d0)"
    load emit_client
    eq '300:1111:2222:3333::10' "$(dhcpv6_lease_for_mac AA:BB:CC:DD:EE:FF)"
    eq '' "$(dhcpv6_lease_for_mac 00:00:00:00:00:00)"
    eq '' "$(dhcpv6_lease_for_mac 11:22:33:44:55:77)"

    PRIVACY='300:1111:2222:3333:1234:5678:abcd:9999'
    ip() { printf '%s\n' "$PRIVACY lladdr $MAC REACHABLE"; }
    YGG_NODE_ROWS=''
    EMITTED_MACS=''; PERSISTENT_MACS=''; LAN_ADDR_ROWS=''
    LAN_CACHE_FILE="$TMP/lease-lan"; LAN_STORE_FILE="$TMP/lease-lan.flash"
    ygg_node_is_live() { return 1; }
    ygg_node_addresses_for_mac() { :; }
    probe_online() { return 1; }
    find_canonical_domain() { CANONICAL_IPV6=''; DNS_ALIAS=''; }
    json_add_object() { :; }; json_close_object() { :; }
    json_add_array() { :; }; json_close_array() { :; }
    json_add_int() { :; }
    json_add_string() { case "$1" in ipv6) GOT_IPV6="$2" ;; ipv6_source) GOT_SOURCE="$2" ;; esac; }
    GOT_IPV6=''; GOT_SOURCE=''
    emit_client host "$MAC" 192.0.2.1 0 200 '' 0 0 0 0
    eq '300:1111:2222:3333::10' "$GOT_IPV6"
    eq "300:1111:2222:3333::10 $PRIVACY" "$KNOWN_IPV6"
    eq dhcpv6 "$GOT_SOURCE"
    # a canonical record still outranks the lease
    find_canonical_domain() { CANONICAL_IPV6='300:1111:2222:3333::5'; DNS_ALIAS=host.home.arpa; }
    EMITTED_MACS=''
    emit_client host "$MAC" 192.0.2.1 1 200 '' 0 0 0 0
    eq '300:1111:2222:3333::5' "$GOT_IPV6"
    eq canonical "$GOT_SOURCE"
    # an IPv4 reservation without hostid is an implicit IPv6 reservation
    # (.235 -> ::235): flagged reserved when the lease landed there, but it
    # does not protect the row the way an explicit hostid does
    GOT_RESERVED=''; GOT_PROTECTED=''
    json_add_int() { case "$1" in reserved_ipv6) GOT_RESERVED="$2" ;; protected_host) GOT_PROTECTED="$2" ;; esac; }
    DHCPV6_LEASES='aa:bb:cc:dd:ee:ff 300:1111:2222:3333::235'
    find_canonical_domain() { CANONICAL_IPV6=''; DNS_ALIAS=''; }
    EMITTED_MACS=''
    emit_client host "$MAC" 192.0.2.235 1 200 192.0.2.235 0 0 0 0 0
    eq 1 "$GOT_RESERVED"
    eq 0 "$GOT_PROTECTED"
    EMITTED_MACS=''
    emit_client host "$MAC" 192.0.2.236 1 200 192.0.2.236 0 0 0 0 0
    eq 0 "$GOT_RESERVED"
    EMITTED_MACS=''
    emit_client host "$MAC" 192.0.2.235 1 200 192.0.2.235 0 0 0 0 1
    eq 1 "$GOT_RESERVED"
    eq 1 "$GOT_PROTECTED"
    # ... unless the hostid was written by this page's own Pin: then Unpin may take it
    EMITTED_MACS=''
    emit_client host "$MAC" 192.0.2.235 1 200 192.0.2.235 1 0 0 0 1
    eq 1 "$GOT_RESERVED"
    eq 0 "$GOT_PROTECTED"
    json_add_int() { :; }
    DHCPV6_LEASES="$(printf '%s\n' \
        'aa:bb:cc:dd:ee:ff 300:1111:2222:3333::10 zeonux' \
        '11:22:33:44:55:66 300:1111:2222:3333::20 -')"
    # no lease for this MAC: the observed set is untouched
    find_canonical_domain() { CANONICAL_IPV6=''; DNS_ALIAS=''; }
    ip() { printf '%s\n' "$PRIVACY lladdr 22:33:44:55:66:77 REACHABLE"; }
    EMITTED_MACS=''
    emit_client other 22:33:44:55:66:77 192.0.2.2 0 200 '' 0 0 0 0
    eq "$PRIVACY" "$GOT_IPV6"
    eq observed "$GOT_SOURCE"
}

# The routed-prefix addresses come from NDP, which forgets a device as soon as
# it goes quiet - long before its row expires. A pinned row keeps them the same
# way it keeps its node address, and on the same storage class.
pinned_lan_memory() {
    LAN_CACHE_FILE="$TMP/pin-lan"
    LAN_STORE_FILE="$TMP/pin-lan.flash"
    LAN_YGG_PREFIX='303:170f:3ab2:166e:'
    PINNED='14:4f:8a:8d:19:77'
    LEASED='aa:bb:cc:dd:ee:03'
    ADDR='303:170f:3ab2:166e:976f:bee8:ff00:b602'
    OTHER='303:170f:3ab2:166e:6e92:bfff:fe2f:aa2a'
    YGG_NODE_ROWS=''

    # Both devices are seen on the LAN; only the pinned one reaches flash.
    LAN_ADDR_ROWS=''
    KNOWN_IPV6="$ADDR"; remember_lan_addresses "$PINNED" 1
    KNOWN_IPV6="$OTHER"; remember_lan_addresses "$LEASED" 1
    EMITTED_MACS="|$PINNED||$LEASED|"
    PERSISTENT_MACS="|$PINNED|"
    save_address_memory
    eq "$(printf '%s\n' "$PINNED $ADDR" "$LEASED $OTHER")" "$(cat "$LAN_CACHE_FILE")"
    eq "$PINNED $ADDR" "$(cat "$LAN_STORE_FILE")"

    # An unchanged run must not rewrite flash: the file is replaced by rename,
    # so an unchanged inode proves no write happened.
    INODE="$(ls -i "$LAN_STORE_FILE" | awk '{print $1}')"
    save_address_memory
    eq "$INODE" "$(ls -i "$LAN_STORE_FILE" | awk '{print $1}')"

    # Reboot: tmpfs is gone and nothing has been seen yet. The pinned row
    # recalls its address; the lease-backed row is forgotten, as intended.
    rm -f "$LAN_CACHE_FILE"
    eq "$ADDR" "$(recall_lan_addresses "$PINNED")"
    eq '' "$(recall_lan_addresses "$LEASED")"

    # A device with several addresses keeps all of them, deduplicated across
    # the two memories.
    LAN_ADDR_ROWS=''
    KNOWN_IPV6="$ADDR $OTHER"; remember_lan_addresses "$PINNED" 1
    EMITTED_MACS="|$PINNED|"
    save_address_memory
    eq "$(printf '%s\n' "$ADDR" "$OTHER")" "$(recall_lan_addresses "$PINNED")"

    # Once the router's routed prefix changes, every address remembered under
    # the old one is dead and must not be offered as if it still worked.
    LAN_YGG_PREFIX='303:dead:beef:1:'
    eq '' "$(recall_lan_addresses "$PINNED")"
    LAN_YGG_PREFIX='303:170f:3ab2:166e:'

    # Unpin: flash forgets the row while tmpfs keeps it for as long as the row
    # itself lasts.
    PERSISTENT_MACS=''
    save_address_memory
    eq '' "$(cat "$LAN_STORE_FILE")"
    eq "$(printf '%s\n' "$PINNED $ADDR" "$PINNED $OTHER")" "$(cat "$LAN_CACHE_FILE")"

    # A missing memory is an empty memory, not an error.
    rm -f "$LAN_CACHE_FILE" "$LAN_STORE_FILE"
    eq '' "$(recall_lan_addresses "$PINNED")"

    # A pass with no routed prefix observes nothing and recalls nothing, so it
    # must not prune: the memory would be destroyed by a transient fault - a
    # reboot where the Yggdrasil interface is not up yet - instead of by the row
    # going away. The node memory is written on such a pass as before.
    LAN_ADDR_ROWS=''
    KNOWN_IPV6="$ADDR"; remember_lan_addresses "$PINNED" 1
    EMITTED_MACS="|$PINNED|"; PERSISTENT_MACS="|$PINNED|"
    save_address_memory
    eq "$PINNED $ADDR" "$(cat "$LAN_STORE_FILE")"
    LAN_YGG_PREFIX=''
    LAN_ADDR_ROWS=''
    save_address_memory
    eq "$PINNED $ADDR" "$(cat "$LAN_STORE_FILE")"
    eq "$PINNED $ADDR" "$(cat "$LAN_CACHE_FILE")"
    LAN_YGG_PREFIX='303:170f:3ab2:166e:'

    # A recalled address is reported as not live, so the UI can grey it out
    # instead of presenting it as a current observation.
    LAN_ADDR_ROWS=''
    KNOWN_IPV6="$ADDR"; remember_lan_addresses "$PINNED" 1
    EMITTED_MACS="|$PINNED|"; PERSISTENT_MACS="|$PINNED|"
    save_address_memory
    LIVE=''
    ygg_node_is_live() { return 1; }
    find_canonical_domain() { CANONICAL_IPV6=''; DNS_ALIAS=''; }
    build_known_ipv6() { KNOWN_IPV6=''; }
    probe_online() { return 1; }
    json_add_object() { :; }; json_close_object() { :; }
    json_add_array() { :; }; json_close_array() { :; }
    json_add_string() { :; }
    json_add_int() { if [ "$1" = ipv6_live ]; then LIVE="$2"; fi; }
    CANONICAL_IPV6=''; DNS_ALIAS=''
    LAN_ADDR_ROWS=''
    DISCOVERY_WANTED=0
    emit_client pc "$PINNED" 192.0.2.5 1 200 '' 0 0 0 0
    eq 0 "$LIVE"
    eq "$PINNED $ADDR 0" "$(printf '%s' "$LAN_ADDR_ROWS" | head -n 1)"

    # An absent device is no reason to disturb the LAN; a present one whose
    # address the router cannot currently see is.
    eq 0 "$DISCOVERY_WANTED"
    probe_online() { return 0; }
    emit_client pc "$PINNED" 192.0.2.5 1 200 '' 0 0 0 0
    eq 1 "$DISCOVERY_WANTED"
}

# The router cannot derive a silent host's SLAAC address, so it asks the LAN for
# it - sourced from the routed prefix, or the replies would be link-local only.
address_discovery() {
    LAN_DEV=br-lan
    LAN_YGG_PREFIX='303:170f:3ab2:166e:'
    PROBE="$TMP/discovery"
    rm -f "$PROBE"
    ip() { printf '    inet6 303:170f:3ab2:166e::1/64 scope global\n    inet6 fe80::1/64 scope link\n'; }
    REPLIES="$TMP/replies"
    printf '%s\n' \
        '64 bytes from 303:170f:3ab2:166e::1: seq=0 ttl=64 time=0.3 ms' \
        '64 bytes from 303:170f:3ab2:166e:aaaa::9: seq=0 ttl=64 time=0.6 ms (DUP!)' \
        '64 bytes from 303:170f:3ab2:166e:aaaa::9: seq=1 ttl=64 time=0.6 ms (DUP!)' \
        '64 bytes from fe80::1234: seq=1 ttl=64 time=0.7 ms (DUP!)' \
        '64 bytes from 300:dead:beef:1:bbbb::7: seq=1 ttl=64 time=0.8 ms (DUP!)' > "$REPLIES"
    ping() {
        printf '%s\n' "$*" >> "$PROBE"
        case "$*" in *ff02::1*) cat "$REPLIES" ;; esac
    }

    # A settled LAN is never probed.
    DISCOVERY_WANTED=0
    discover_lan_addresses
    wait
    if [ -f "$PROBE" ]; then fail 'probed a settled LAN'; fi

    # The multicast ask is sourced from the router's routed address, and every
    # address it turns up is confirmed once so the neighbour table records it
    # with its MAC. The router's own address, a link-local reply, a foreign
    # prefix and a repeated address must not each earn a probe.
    DISCOVERY_WANTED=1
    discover_lan_addresses
    wait
    eq "$(printf '%s\n' \
        '-6 -c 3 -W 2 -I 303:170f:3ab2:166e::1 ff02::1%br-lan' \
        '-6 -c 1 -W 1 303:170f:3ab2:166e:aaaa::9')" "$(cat "$PROBE")"

    # Without a routed address on the bridge there is nothing to source from,
    # and a link-local source would defeat the purpose.
    rm -f "$PROBE"
    ip() { printf '    inet6 fe80::1/64 scope link\n'; }
    discover_lan_addresses
    wait
    if [ -f "$PROBE" ]; then fail 'probed without a routed source address'; fi

    unset -f ip ping
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
    uci() { case "$1" in -q) return 1 ;; *) fail 'protected RPC reached UCI mutation' ;; esac; }
    backup_dhcp_config() { fail 'protected RPC reached backup/mutation'; }
    PIN_SECTION_PREFIX=ygg_status_
    FOUND_HOST_MATCH_COUNT=1
    FOUND_HOST_MAC_COUNT=1
    FOUND_HOST_COMPLEX=0
    FOUND_HOST_HOSTID=''
    FOUND_HOST_MANAGED=0
    config_foreach() { :; }
    select_ygg_network() { :; }
    find_lan_ygg_prefix() { echo '300:1111:2222:3333:'; }
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
    FOUND_HOST_HOSTID=10
    rpc_unpin
    eq reserved_ipv6 "$CODE"
    # a hostid this page's own Pin wrote goes with the pin, after confirmation
    FOUND_HOST_MANAGED=1
    ADDR6=''
    json_reply_device() { CODE="$2"; ADDR6="${7:-}"; }
    rpc_unpin
    eq static_confirmation_required "$CODE"
    eq '300:1111:2222:3333::10' "$ADDR6"
    json_reply_device() { CODE="$2"; }
    FOUND_HOST_MANAGED=0
    FOUND_HOST_HOSTID=''
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
    # IPv6 suffix: only where DHCPv6 is served, valid, and not taken
    json_get_var() { case "$2" in mac) eval "$1='aa:bb:cc:dd:ee:ff'" ;; name) eval "$1='Host'" ;; reserve_ipv6) eval "$1=\"\$WANT6\"" ;; *) eval "$1='false'" ;; esac; }
    lan_dhcpv6_is_served() { return 1; }
    WANT6=10; rpc_pin
    eq dhcpv6_not_served "$CODE"
    lan_dhcpv6_is_served() { return 0; }
    for bad in 0 1 000 zz 12345678901234567 0x0; do
        WANT6="$bad"; rpc_pin
        eq invalid_hostid "$CODE"
    done
    config_foreach() { collect_taken_hostid other; }
    config_get() { case "$3" in hostid) eval "$1='0x10'" ;; ip) eval "$1=''" ;; esac; }
    WANT6=010; rpc_pin
    eq hostid_taken "$CODE"
    config_get() { case "$3" in hostid) eval "$1=''" ;; ip) eval "$1='192.0.2.235'" ;; esac; }
    WANT6=235; rpc_pin
    eq hostid_taken "$CODE"
    # hex identifiers are compared as strings: 100 and 1e2 are different suffixes
    config_get() { case "$3" in hostid) eval "$1='100'" ;; ip) eval "$1=''" ;; esac; }
    lease_duid_for_mac() { :; }
    dhcp_has_pending_changes() { return 0; }
    WANT6=1e2; rpc_pin
    eq pending_uci_changes "$CODE"
    dhcp_has_pending_changes() { return 1; }
    # an IPv6-only client (no DHCPv4 lease) can still be pinned through its bound DHCPv6 lease
    find_active_lease_by_mac() { return 1; }
    config_foreach() { :; }
    collect_host_duids() { :; }
    collect_dhcpv6_leases() { DHCPV6_LEASES='aa:bb:cc:dd:ee:ff 300:1111:2222:3333::77 v6only'; }
    find_lan_ygg_prefix() { echo '300:1111:2222:3333:'; }
    select_ygg_network() { :; }
    WANT6=''
    json_get_var() { case "$2" in mac) eval "$1='aa:bb:cc:dd:ee:ff'" ;; name) eval "$1=''" ;; *) eval "$1='false'" ;; esac; }
    dhcp_has_pending_changes() { return 0; }
    rpc_pin
    eq pending_uci_changes "$CODE"
    eq v6only "$LEASE_MATCH_NAME"
    eq '' "$LEASE_MATCH_IPV4"
    find_active_lease_by_mac() { LEASE_MATCH_NAME=Host; LEASE_MATCH_IPV4=192.0.2.1; return 0; }
    dhcp_has_pending_changes() { return 1; }
    WANT6=''
    json_get_var() { case "$2" in mac) eval "$1='aa:bb:cc:dd:ee:ff'" ;; name) eval "$1='Host'" ;; *) eval "$1='false'" ;; esac; }
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
run 'DHCPv6 leases are attributed by DUID MAC and outrank observed addresses' dhcpv6_lease_source
run 'a pinned row keeps its routed addresses across a reboot' pinned_lan_memory
run 'Unpin destructive and pending-change guards' unpin_guards
run 'Pin existing, expired, pending-change and busy guards' pin_guards
run 'routed address discovery is sourced and gated' address_discovery
printf '%s backend fixture groups passed\n' "$COUNT"
