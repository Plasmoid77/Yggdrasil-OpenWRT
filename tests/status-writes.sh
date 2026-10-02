#!/bin/sh
# shellcheck disable=SC2034,SC2317,SC2329,SC2016
# Pin and Unpin past their guards: the writes they make, the commit and the
# service reloads, and the rollback when a step fails. The production
# functions run against an in-memory UCI: `uci` and the /lib/functions.sh
# config_* helpers are emulated over one file in `uci show` format, which is
# also the DHCP configuration file the backend backs up and restores.
set -u
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
for fn in lower normalize_mac valid_mac valid_hostname valid_ipv4 first_ipv4 lease_is_active \
    find_active_lease_by_mac match_host_section_by_mac find_host_by_mac host_section_has_extra_options \
    backup_dhcp_config restore_dhcp_config finish_dhcp_config dhcp_has_pending_changes \
    dhcpv6_is_served lan_dhcpv6_is_served commit_and_reload_dhcp norm_hostid valid_hostid \
    collect_taken_hostids collect_taken_hostid iid_to_addr load_ygg_prefix rpc_pin rpc_unpin; do
    load "$fn"
done
eval "$(sed -n "s/^\(PIN_SECTION_PREFIX\|LAN_NET\)=/&/p" "$SOURCE")"

# --- in-memory UCI -----------------------------------------------------------
STORE="$TMP/dhcp"          # committed state, `uci show` lines; also DHCP_CONFIG
STAGE="$TMP/stage"         # staged changes: "set KEY=VALUE" / "delete KEY"
DHCP_CONFIG="$STORE"
: > "$STAGE"
view() {   # committed state with the staged changes applied
    cp "$STORE" "$TMP/view"
    while IFS= read -r vw_op; do
        vw_key="${vw_op#* }"; vw_key="${vw_key%%=*}"
        awk -v k="$vw_key" 'index($0, k "=") != 1 && index($0, k ".") != 1' "$TMP/view" > "$TMP/view.n"
        mv "$TMP/view.n" "$TMP/view"
        case "$vw_op" in
            set\ *.*.*=*) printf "%s='%s'\n" "$vw_key" "${vw_op#*=}" >> "$TMP/view" ;;
            set\ *)       printf '%s\n' "${vw_op#set }" >> "$TMP/view" ;;
        esac
    done < "$STAGE"
    cat "$TMP/view"
}
uci() {
    [ "$1" = -q ] && shift
    case "$1" in
        get)     view | awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2); gsub(/\047/, "", v); print v; f = 1 } END { exit !f }' ;;
        show)    view | awk -v k="$2" 'index($0, k) == 1' ;;
        set)     printf 'set %s\n' "$2" >> "$STAGE" ;;
        delete)  view | grep -q "^$2[=.]" || return 1; printf 'delete %s\n' "$2" >> "$STAGE" ;;
        changes) cat "$STAGE" ;;
        revert)  : > "$STAGE" ;;
        commit)  [ "${FAIL_COMMIT:-0}" = 1 ] && return 1
                 view > "$STORE.n" && mv "$STORE.n" "$STORE" && : > "$STAGE" ;;
        *)       fail "unexpected uci $*" ;;
    esac
}
config_load() { :; }
config_foreach() {   # $1 = callback, $2 = section type, $3.. = extra arguments
    cf_fn="$1"; cf_type="$2"; shift 2
    for cf_sec in $(view | sed -n "s/^dhcp\.\([^.=]*\)=$cf_type\$/\1/p"); do "$cf_fn" "$cf_sec" "$@"; done
}
config_get() {       # $1 = variable, $2 = section, $3 = option
    eval "$1=\$(uci -q get 'dhcp.$2.$3')"
}

# --- services and RPC plumbing -----------------------------------------------
INITD="$TMP/init.d"; mkdir -p "$INITD"
for svc in dnsmasq odhcpd; do
    printf '#!/bin/sh\necho "%s $1" >> "%s/services"\n[ "${FAIL_%s:-0}" != 1 ]\n' "$svc" "$TMP" "$svc" > "$INITD/$svc"
    chmod 755 "$INITD/$svc"
done
export FAIL_dnsmasq FAIL_odhcpd   # the init scripts are separate processes
read_request() { return 0; }
REQUEST=''
json_get_var() { eval "$1=\$(printf '%s\n' \"\$REQUEST\" | sed -n 's/^$2=//p')"; }
json_reply() { CODE="$2"; }
json_reply_device() { CODE="$2"; ADDR6="${7:-}"; }
acquire_dhcp_lock() { return 0; }
select_ygg_network() { :; }
find_lan_ygg_prefix() { echo '300:1111:2222:3333:'; }
collect_host_duids() { :; }
lease_duid_for_mac() { printf '%s\n' "${LEASE_DUID:-}"; }
LEASE_FILE="$TMP/dhcp.leases"
NOW=100
date() { echo 100; }
COUNT=0
run() { COUNT=$((COUNT + 1)); ( "$2" ) || fail "$1"; printf 'PASS: %s\n' "$1"; }

reset() {
    cat > "$STORE" <<'EOF'
dhcp.lan=dhcp
dhcp.lan.interface='lan'
dhcp.lan.dhcpv6='server'
dhcp.cfg01=host
dhcp.cfg01.name='printer'
dhcp.cfg01.mac='11:22:33:44:55:66'
dhcp.cfg01.ip='192.0.2.50'
EOF
    : > "$STAGE"; : > "$TMP/services"
    printf '%s\n' '9999 aa:bb:cc:dd:ee:ff 192.0.2.10 laptop *' > "$LEASE_FILE"
    CODE=''; ADDR6=''; FAIL_COMMIT=0; FAIL_dnsmasq=0; FAIL_odhcpd=0; LEASE_DUID=''
    PIN_SECTION_PREFIX='ygg_status_'
}

pin_writes() {
    reset
    REQUEST='mac=AA:BB:CC:DD:EE:FF
name=laptop'
    rpc_pin
    eq pinned "$CODE"
    eq host "$(uci -q get dhcp.ygg_status_aabbccddeeff)"
    eq laptop "$(uci -q get dhcp.ygg_status_aabbccddeeff.name)"
    eq aa:bb:cc:dd:ee:ff "$(uci -q get dhcp.ygg_status_aabbccddeeff.mac)"
    if uci -q get dhcp.ygg_status_aabbccddeeff.ip >/dev/null; then fail 'IPv4 reserved without being asked'; fi
    eq '' "$(cat "$STAGE")"
    eq "$(printf 'dnsmasq reload\nodhcpd reload')" "$(cat "$TMP/services")"
    # the same device again is already persistent, and nothing changes
    cp "$STORE" "$TMP/before"
    rpc_pin
    eq already_persistent "$CODE"
    cmp -s "$STORE" "$TMP/before" || fail 'a second Pin changed the configuration'
}

pin_reservations() {
    reset
    LEASE_DUID='0004aabbccdd%1'
    REQUEST='mac=aa:bb:cc:dd:ee:ff
name=laptop
reserve_ipv4=true
reserve_ipv6=20'
    rpc_pin
    eq pinned "$CODE"
    eq 192.0.2.10 "$(uci -q get dhcp.ygg_status_aabbccddeeff.ip)"
    eq 20 "$(uci -q get dhcp.ygg_status_aabbccddeeff.hostid)"
    eq '0004aabbccdd%1' "$(uci -q get dhcp.ygg_status_aabbccddeeff.duid)"
    eq '300:1111:2222:3333::20' "$ADDR6"
    # a suffix another host already holds is refused before any write
    reset
    printf "set dhcp.cfg01.hostid=20\n" > "$STAGE"; uci commit dhcp
    REQUEST='mac=aa:bb:cc:dd:ee:ff
name=laptop
reserve_ipv6=20'
    cp "$STORE" "$TMP/before"
    rpc_pin
    eq hostid_taken "$CODE"
    cmp -s "$STORE" "$TMP/before" || fail 'a refused Pin changed the configuration'
}

pin_rollback() {
    # commit refused: nothing reaches the file, the staged edit is reverted
    reset
    cp "$STORE" "$TMP/before"
    REQUEST='mac=aa:bb:cc:dd:ee:ff
name=laptop'
    FAIL_COMMIT=1
    rpc_pin
    eq reload_failed "$CODE"
    cmp -s "$STORE" "$TMP/before" || fail 'a failed commit left changes behind'
    eq '' "$(cat "$STAGE")"
    # odhcpd refuses the new file: the old file returns and both daemons reread it
    reset
    cp "$STORE" "$TMP/before"
    FAIL_odhcpd=1
    rpc_pin
    eq reload_failed "$CODE"
    cmp -s "$STORE" "$TMP/before" || fail 'the previous configuration was not restored'
    eq "$(printf 'dnsmasq reload\nodhcpd reload\ndnsmasq reload\nodhcpd reload')" "$(cat "$TMP/services")"
    [ ! -e "/tmp/yggdrasil-status-dhcp.$$.bak" ] || fail 'backup left behind'
}

unpin_writes() {
    reset
    REQUEST='mac=aa:bb:cc:dd:ee:ff
name=laptop
reserve_ipv4=true'
    rpc_pin
    eq pinned "$CODE"
    # a static reservation needs the confirmation, then the section goes
    REQUEST='mac=aa:bb:cc:dd:ee:ff'
    rpc_unpin
    eq static_confirmation_required "$CODE"
    eq ygg_status_aabbccddeeff "$(view | sed -n 's/^dhcp\.\(ygg_status_[^.=]*\)=host$/\1/p')"
    REQUEST='mac=aa:bb:cc:dd:ee:ff
confirm_static=true'
    : > "$TMP/services"
    rpc_unpin
    eq unpinned "$CODE"
    if view | grep -q '^dhcp\.ygg_status_'; then fail 'the pin section survived Unpin'; fi
    eq printer "$(uci -q get dhcp.cfg01.name)"
    eq '' "$(cat "$STAGE")"
    eq "$(printf 'dnsmasq reload\nodhcpd reload')" "$(cat "$TMP/services")"
    # a plain hand-made (anonymous, cfgNN) reservation goes the same way
    REQUEST='mac=11:22:33:44:55:66
confirm_static=true'
    rpc_unpin
    eq unpinned "$CODE"
    if view | grep -q '^dhcp\.cfg01'; then fail 'the anonymous section survived Unpin'; fi
    eq dhcp "$(uci -q get dhcp.lan)"
    # a hand-made section with a tag is protected: nothing is deleted
    reset
    printf "set dhcp.cfg01.tag=iot\n" > "$STAGE"; uci commit dhcp
    cp "$STORE" "$TMP/before"
    REQUEST='mac=11:22:33:44:55:66
confirm_static=true'
    rpc_unpin
    eq complex_host "$CODE"
    cmp -s "$STORE" "$TMP/before" || fail 'a protected section was changed'
}

host_lookup() {
    reset
    printf '%s\n' "set dhcp.cfg02=host" "set dhcp.cfg02.mac=11:22:33:44:55:66 aa:aa:aa:aa:aa:aa" > "$STAGE"; uci commit dhcp
    find_host_by_mac 11:22:33:44:55:66 || fail 'host not found'
    eq 2 "$FOUND_HOST_MATCH_COUNT"
    eq 1 "$FOUND_HOST_AMBIGUOUS"
    eq cfg01 "$FOUND_HOST_SECTION"
    eq 192.0.2.50 "$FOUND_HOST_STATIC_IPV4"
    find_host_by_mac AA:AA:AA:AA:AA:AA || fail 'second MAC of a shared section not found'
    eq 2 "$FOUND_HOST_MAC_COUNT"
    if find_host_by_mac de:ad:be:ef:00:01; then fail 'an unknown MAC was found'; fi
}

run 'Pin writes name and MAC, commits and reloads; a second Pin changes nothing' pin_writes
run 'Pin stores IPv4, hostid and DUID; a taken suffix is refused before any write' pin_reservations
run 'a refused commit or reload brings the previous DHCP configuration back' pin_rollback
run 'Unpin deletes a confirmed pin and leaves protected sections alone' unpin_writes
run 'config host lookup: duplicates, shared sections, unknown MACs' host_lookup
printf '%s write-path groups passed\n' "$COUNT"
