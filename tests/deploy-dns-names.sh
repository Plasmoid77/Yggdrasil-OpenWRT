#!/bin/sh
# shellcheck disable=SC2012,SC2034,SC2317,SC2329,SC2016
# Stage 6 publishes the router's Yggdrasil names through a generator of its own
# (/etc/yggdrasil-openwrt/dns-hosts) that writes a hosts file for dnsmasq from
# the node's current address and routed /64, so the names follow a node key
# changed by hand. The generator and the hotplug hook are extracted from the
# deployer and run against stubbed ifstatus/jsonfilter; the name validation
# block runs as written in the deployer.

set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/deploy/deploy-openwrt-yggdrasil.sh"
TMP="$(mktemp -d /tmp/ygg-dns-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

extract_function() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\)" { found = 1 }
        found { print }
        found && /^}$/ { exit }
    ' "$SCRIPT"
}
for f in addr_awk lower_str dns_conf_text dns_gen_text dns_hook_text; do
    body="$(extract_function "$f")"
    [ -n "$body" ] || { echo "FAIL: function $f not found in deployer" >&2; exit 1; }
    eval "$body"
done
fail() { echo "FAIL: $*" >&2; exit 1; }

# stubs: ifstatus prints nothing, jsonfilter answers from NODE / PFX
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/ifstatus"
cat > "$TMP/bin/jsonfilter" <<'EOF'
#!/bin/sh
case "$*" in
    *ipv6-address*) [ -n "${NODE:-}" ] && echo "$NODE" ;;
    *ipv6-prefix*)  [ -n "${PFX:-}" ] && echo "$PFX" ;;
esac
exit 0
EOF
chmod 755 "$TMP/bin/ifstatus" "$TMP/bin/jsonfilter"

IFACE='ygg0'; DNS_DOMAIN='spb.home.arpa'; DNS_ROUTER='router'
DNS_GEN='/etc/yggdrasil-openwrt/dns-hosts'
HOSTS='Zeonux mac 6c:92:bf:2f:aa:28 10
cam mac aa:bb:cc:dd:ee:70 a0b0000000000001'
DNS_HOSTS='peer=201:6cc9:12e5:e0a2:f3e1:7297:b4bd:c947'

dns_conf_text > "$TMP/dns.conf"
dns_gen_text > "$TMP/dns-hosts"
sh -n "$TMP/dns-hosts" || fail 'generator does not parse'
busybox ash -n "$TMP/dns-hosts" || fail 'generator does not parse under BusyBox ash'
grep -qx 'host zeonux 10' "$TMP/dns.conf" || fail "conf does not carry the lower-cased reservation: $(cat "$TMP/dns.conf")"

gen() {
    PATH="$TMP/bin:$PATH" YGG_DNS_CONF="$TMP/dns.conf" YGG_HOSTS_DIR="$TMP/hosts" \
        YGG_DNS_LOCK="$TMP/lock" YGG_DNS_NOSIGNAL=1 NODE="$NODE" PFX="$PFX" sh "$TMP/dns-hosts"
}
OUT="$TMP/hosts/yggdrasil-ygg0"

# 1. names from the current node address and /64
NODE='203:170f:3ab2:166e:6d0d:af56:91ec:43fc'; PFX='303:170f:3ab2:166e::'
gen
want='203:170f:3ab2:166e:6d0d:af56:91ec:43fc router.spb.home.arpa
303:170f:3ab2:166e::10 zeonux.spb.home.arpa
303:170f:3ab2:166e:a0b0::1 cam.spb.home.arpa
201:6cc9:12e5:e0a2:f3e1:7297:b4bd:c947 peer.spb.home.arpa'
[ "$(cat "$OUT")" = "$want" ] || fail "hosts file:
$(cat "$OUT")"
for f in "$TMP/hosts"/.[!.]*; do [ -e "$f" ] && fail "a temporary dot file was left behind: $f"; done
echo 'PASS: names from the current node address and /64'

# 2. unchanged state: the file is not rewritten
# a rewrite goes through mv, which gives the file a new inode
ino() { ls -i "$1" | awk '{ print $1 }'; }
before="$(ino "$OUT")"
gen
[ "$(ino "$OUT")" = "$before" ] || fail 'an unchanged hosts file was rewritten'
NODE='203:170f:3ab2:166e:6d0d:af56:91ec:43fd'; gen
[ "$(ino "$OUT")" != "$before" ] || fail 'a changed hosts file was not replaced (inode check is blind)'
NODE='203:170f:3ab2:166e:6d0d:af56:91ec:43fc'; gen
echo 'PASS: an unchanged state leaves the file alone'

# 3. a new node key: every derived name moves, the static one stays
NODE='200:6bb0:a82d:16fc:e0b5:3a72:be4f:e58e'; PFX='300:6bb0:a82d:16fc::'
gen
grep -qx '200:6bb0:a82d:16fc:e0b5:3a72:be4f:e58e router.spb.home.arpa' "$OUT" || fail "router not moved: $(cat "$OUT")"
grep -qx '300:6bb0:a82d:16fc::10 zeonux.spb.home.arpa' "$OUT" || fail "reservation not moved: $(cat "$OUT")"
grep -q '303:170f' "$OUT" && fail "old /64 still published: $(cat "$OUT")"
grep -qx '201:6cc9:12e5:e0a2:f3e1:7297:b4bd:c947 peer.spb.home.arpa' "$OUT" || fail 'static name lost'
echo 'PASS: a new node key moves the derived names'

# 4. zero groups in the /64 compress correctly
NODE='200:0:a82d:0:1:2:3:4'; PFX='300:0:a82d::'
gen
grep -qx '300:0:a82d:0::10 zeonux.spb.home.arpa' "$OUT" && fail 'ambiguous compression'
grep -qx '300:0:a82d::10 zeonux.spb.home.arpa' "$OUT" || fail "zero groups: $(cat "$OUT")"
echo 'PASS: zero groups in the prefix'

# 5. interface down: the file goes away; down again: nothing to do
NODE=''; PFX=''
gen
[ ! -e "$OUT" ] || fail 'hosts file kept while the interface is down'
gen
echo 'PASS: interface down removes the names'

# 6. the hook: carries the interface and the generator, reacts to ifup/ifupdate/ifdown only
dns_hook_text > "$TMP/hook"
sh -n "$TMP/hook" || fail 'hook does not parse'
grep -q '@' "$TMP/hook" && fail "unexpanded placeholder in hook: $(cat "$TMP/hook")"
grep -qx "\[ \"\$INTERFACE\" = 'ygg0' \] || exit 0" "$TMP/hook" || fail 'hook does not filter the interface'
grep -qx "\[ -x '/etc/yggdrasil-openwrt/dns-hosts' \] && '/etc/yggdrasil-openwrt/dns-hosts'" "$TMP/hook" \
    || fail 'hook does not run the generator'
sed "s|/etc/yggdrasil-openwrt/dns-hosts|$TMP/ran|g" "$TMP/hook" > "$TMP/hook.t"
printf '#!/bin/sh\necho ran >> "%s/ran.log"\n' "$TMP" > "$TMP/ran"; chmod 755 "$TMP/ran"
for a in ifup ifupdate ifdown ifup-failed; do INTERFACE=ygg0 ACTION=$a sh "$TMP/hook.t"; done
INTERFACE=lan ACTION=ifup sh "$TMP/hook.t"
[ "$(wc -l < "$TMP/ran.log")" -eq 3 ] || fail "hook ran $(wc -l < "$TMP/ran.log") times, want 3"
echo 'PASS: the hook runs the generator on ifup, ifupdate and ifdown of ygg0'

# 7. name validation, as written in the deployer
VALIDATE="$(sed -n '/^dns_label_ok() {$/,/^# Ask for the Yggdrasil/p' "$SCRIPT" | sed '$d')"
[ -n "$VALIDATE" ] || fail 'validation block not found'
validate() { # $1 domain $2 router $3 dns-hosts $4 hosts
    (
        die() { echo "$*"; exit 1; }
        DO_DNS=1; DNS_DOMAIN="$1"; DNS_ROUTER="$2"; DNS_HOSTS="$3"; HOSTS="$4"
        eval "$VALIDATE"
        echo "ok $DNS_DOMAIN $DNS_ROUTER"
    )
}
[ "$(validate 'SPB.Home.Arpa.' router '' '')" = 'ok spb.home.arpa router' ] || fail 'zone not normalised'
for bad in arpa 'arpa..' 'home.arpa..' '.home.arpa' 'spb..home.arpa' '-x.home.arpa' 'x-.internal' 'a_b.internal'; do
    validate "$bad" router '' '' >/dev/null && fail "zone '$bad' accepted"
done
validate home.arpa 'my.router' '' '' >/dev/null && fail 'dotted router name accepted'
validate home.arpa router 'Router=201::1' '' >/dev/null && fail 'router name collision accepted'
validate home.arpa router 'bad_name=201::1' '' >/dev/null && fail 'invalid --dns-host label accepted'
validate home.arpa router '' 'Router mac aa:bb:cc:dd:ee:ff 10' >/dev/null && fail '--host named like the router accepted'
validate lab.internal router 'peer=201::1' 'zeonux mac aa:bb:cc:dd:ee:ff 10' >/dev/null || fail 'a valid set was refused'
echo 'PASS: zone and name validation'

# 8. no character classes in tr: the router's BusyBox tr lacks them and maps
#    the letters of '[:upper:]' instead ("router" became "rolter" on 2.3.0-pre)
grep -n "tr '\[:" "$SCRIPT" && fail 'tr with a character class in the deployer'
[ "$(lower_str 'Router.HOME.Arpa')" = 'router.home.arpa' ] || fail 'lower_str'
echo 'PASS: lower-casing without character classes'

# 9. rollback restores the DNS settings with the UCI files
eval "$(extract_function backup_file)"
RB="$(extract_function rollback | sed "s|/etc/init.d/|rb_init |g; s|/etc/config/|$TMP/etc/config/|g")"
[ -n "$RB" ] || fail 'rollback not found'
eval "$RB"
rb_init() { echo "$*" >> "$TMP/init.log"; }
warn() { :; }
uci() { return 0; }
DRY_RUN=0; CHANGED_NETWORK=0; CHANGED_FIREWALL=0; CHANGED_DHCP=1; CHANGED_DNS=1
DNS_CONF="$TMP/etc/dns.conf"; DNS_HOSTS_DIR="$TMP/rbhosts"; DNS_GEN="$TMP/gen"
printf '#!/bin/sh\necho "gen $YGG_DNS_NOSIGNAL" >> "%s/init.log"\n' "$TMP" > "$DNS_GEN"; chmod 755 "$DNS_GEN"
mkdir -p "$TMP/etc/config" "$DNS_HOSTS_DIR"
# a rerun that changed the zone: the old settings come back and the names are rebuilt
BACKUP_DIR="$TMP/bk1"; mkdir -p "$BACKUP_DIR"; echo 'zone home.arpa' > "$BACKUP_DIR/dns.conf"
printf 'original dhcp\n' > "$BACKUP_DIR/dhcp"
echo 'zone spb.home.arpa' > "$DNS_CONF"; : > "$TMP/init.log"
rollback
[ "$(cat "$DNS_CONF")" = 'zone home.arpa' ] || fail "dns.conf not restored: $(cat "$DNS_CONF")"
grep -qx 'gen 1' "$TMP/init.log" || fail 'names not rebuilt on rollback'
[ "$(grep -n . "$TMP/init.log" | grep 'gen 1' | cut -d: -f1)" -lt "$(grep -n 'dnsmasq restart' "$TMP/init.log" | cut -d: -f1)" ] \
    || fail 'names rebuilt after the dnsmasq restart'
# a first run (no dns.conf before): settings and generated names removed
BACKUP_DIR="$TMP/bk2"; mkdir -p "$BACKUP_DIR"; : > "$BACKUP_DIR/dns.conf.absent"
printf 'original dhcp\n' > "$BACKUP_DIR/dhcp"
echo 'zone home.arpa' > "$DNS_CONF"; echo '203::1 router.home.arpa' > "$DNS_HOSTS_DIR/yggdrasil-ygg0"
rollback
if [ -e "$DNS_CONF" ] || [ -e "$DNS_HOSTS_DIR/yggdrasil-ygg0" ]; then fail 'first-run DNS state left after rollback'; fi
# stage 6 not reached: DNS files untouched
CHANGED_DNS=0; echo 'zone x.internal' > "$DNS_CONF"
rollback
[ "$(cat "$DNS_CONF")" = 'zone x.internal' ] || fail 'dns.conf touched although stage 6 did not run'
echo 'PASS: rollback restores the DNS settings and names'

# 10. the zones go into dnsmasq's single 'local' value, beside OpenWrt's '/lan/'
eval "$(extract_function dns_local_merge)" || fail 'dns_local_merge not found'
lm() { dns_local_merge "$@" || echo REFUSED; }
[ "$(lm '/lan/' '' 'home.arpa spb.internal')" = '/lan/home.arpa/spb.internal/' ] || fail "stock /lan/: $(lm '/lan/' '' 'home.arpa spb.internal')"
[ "$(lm '' '' 'home.arpa')" = '/home.arpa/' ] || fail "no local value: $(lm '' '' 'home.arpa')"
[ "$(lm '/lan/home.arpa/spb.internal/' 'spb.internal' 'home.arpa blg.internal')" = '/lan/home.arpa/blg.internal/' ] \
    || fail "zone change: $(lm '/lan/home.arpa/spb.internal/' 'spb.internal' 'home.arpa blg.internal')"
[ "$(lm '/LAN/Home.Arpa/office/' '' 'home.arpa')" = '/LAN/Home.Arpa/office/' ] || fail "case/other domains: $(lm '/LAN/Home.Arpa/office/' '' 'home.arpa')"
[ "$(lm '/lan/home.arpa/.spb.internal./' 'spb.internal' 'home.arpa blg.internal')" = '/lan/home.arpa/blg.internal/' ] \
    || fail "dotted spelling of a retired zone kept: $(lm '/lan/home.arpa/.spb.internal./' 'spb.internal' 'home.arpa blg.internal')"
[ "$(lm '/lan/.home.arpa/' '' 'home.arpa')" = '/lan/.home.arpa/' ] || fail "dotted spelling duplicated: $(lm '/lan/.home.arpa/' '' 'home.arpa')"
for bad in '/lan/192.168.1.1' '/lan/ /home.arpa/' 'lan' '/lan//' '/lan/#'; do
    [ "$(lm "$bad" '' 'home.arpa')" = REFUSED ] || fail "not refused: '$bad' -> $(lm "$bad" '' 'home.arpa')"
done
echo 'PASS: local value merge'

# 11. stage 6 against a fake UCI: upgrade, rerun, zone change, odd 'local'
UCIDB="$TMP/uci.db"
uci() {
    [ "$1" = -q ] && shift
    _c="$1"; shift
    case "$_c" in
        get) awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); f = 1 } END { exit !f }' "$UCIDB" ;;
        set) awk -v k="${1%%=*}" 'index($0, k "=") != 1' "$UCIDB" > "$UCIDB.n"
             printf '%s\n' "$1" >> "$UCIDB.n"; mv "$UCIDB.n" "$UCIDB" ;;
        delete) awk -v k="$1" 'index($0, k "=") != 1' "$UCIDB" > "$UCIDB.n"; mv "$UCIDB.n" "$UCIDB" ;;
        add_list) _o="$(uci get "${1%%=*}" 2>/dev/null || true)"; uci set "${1%%=*}=${_o:+$_o }${1#*=}" ;;
        del_list) _n="$(uci get "${1%%=*}" 2>/dev/null | tr ' ' '\n' | grep -vxF "${1#*=}" | tr '\n' ' ' | sed 's/ $//')"
                  if [ -n "$_n" ]; then uci set "${1%%=*}=$_n"; else uci delete "${1%%=*}"; fi ;;
        show|commit) : ;;
    esac
}
ST="$(extract_function stage_dns | sed 's|/etc/init.d/dnsmasq|dnsmasq_init|g')"
[ -n "$ST" ] || fail 'stage_dns not found'
eval "$ST"
for f in dns_uci_records uci_del uci_set uci_add_list uci_del_list dns_zone_is_local; do
    body="$(extract_function "$f")"; [ -n "$body" ] || fail "function $f not found in deployer"; eval "$body"
done
dnsmasq_init() { :; }; pidof() { return 0; }; put_file() { return 0; }; dhcp_lock() { :; }
step() { :; }; info() { :; }; ok() { :; }; warn() { echo "$*" >> "$TMP/warn.log"; }; die() { fail "die: $*"; }
DO_DNS=1; DO_FIREWALL=1; TRUSTED='x'; DRY_RUN=0; DNS_GEN=true; DNS_CONF="$TMP/s6.conf"; DNS_HOOK="$TMP/s6.hook"
run6() { # $1 old dns.conf zone ('' = none), $2 new zone, then 'key=value' rows
    _old="$1"; DNS_DOMAIN="$2"; shift 2
    if [ -n "$_old" ]; then echo "zone $_old" > "$DNS_CONF"; else rm -f "$DNS_CONF"; fi
    : > "$TMP/warn.log"; printf '%s\n' "dhcp.@dnsmasq[0]=dnsmasq" "$@" > "$UCIDB"
    stage_dns
}
loc() { uci -q get 'dhcp.@dnsmasq[0].local' || echo '<unset>'; }
srv() { uci -q get 'dhcp.@dnsmasq[0].server' || echo '<unset>'; }
run6 '' spb.internal 'dhcp.@dnsmasq[0].local=/lan/'
[ "$(loc)|$(srv)" = '/lan/home.arpa/spb.internal/|<unset>' ] || fail "fresh install: $(loc)|$(srv)"
run6 spb.internal spb.internal 'dhcp.@dnsmasq[0].local=/lan/' 'dhcp.@dnsmasq[0].server=/home.arpa/ 9.9.9.9 /spb.internal/'
[ "$(loc)|$(srv)" = '/lan/home.arpa/spb.internal/|9.9.9.9' ] || fail "upgrade from the server list: $(loc)|$(srv)"
cp "$UCIDB" "$TMP/uci.before"; stage_dns
cmp -s "$UCIDB" "$TMP/uci.before" || fail "rerun changed UCI: $(cat "$UCIDB")"
run6 spb.internal blg.internal 'dhcp.@dnsmasq[0].local=/lan/home.arpa/spb.internal/'
[ "$(loc)|$(srv)" = '/lan/home.arpa/blg.internal/|<unset>' ] || fail "zone change: $(loc)|$(srv)"
run6 spb.internal home.arpa 'dhcp.@dnsmasq[0].local=/lan/home.arpa/spb.internal/'
[ "$(loc)" = '/lan/home.arpa/' ] || fail "back to home.arpa: $(loc)"
[ "$(dns_zone_is_local home.arpa)" = yes ] || fail 'home.arpa not reported local'
run6 '' spb.internal 'dhcp.@dnsmasq[0].local=/lan/192.168.1.1'
[ "$(loc)|$(srv)" = '/lan/192.168.1.1|/home.arpa/ /spb.internal/' ] || fail "odd local value: $(loc)|$(srv)"
grep -q 'server list' "$TMP/warn.log" || fail 'odd local value: no warning'
[ "$(dns_zone_is_local spb.internal)" = yes ] || fail 'server-list zone not reported local'
[ "$(dns_zone_is_local blg.internal)" = no ] || fail 'absent zone reported local'
printf '%s\n' 'dhcp.@dnsmasq[0].local=/spb.internal/9.9.9.9' 'dhcp.@dnsmasq[0].server=127.0.0.42' > "$UCIDB"
[ "$(dns_zone_is_local spb.internal)" = no ] || fail 'a forwarding local value reported local'
echo 'PASS: stage 6 keeps the zones in local'

echo 'deploy-dns-names: all checks passed'
