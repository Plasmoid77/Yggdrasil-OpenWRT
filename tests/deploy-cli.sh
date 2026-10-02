#!/bin/sh
# shellcheck disable=SC2034,SC2317,SC2329
# The other deployer tests evaluate extracted functions. This one runs the real
# script, so the option loop and the checks after it execute in file order -
# the order that once left --status-version calling a function defined further
# down. A run that gets through them prints the Stage 0 banner and then stops
# at the preflight (not root, or not OpenWrt); nothing is changed on the host.
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/deploy/deploy-openwrt-yggdrasil.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

for shell in sh 'busybox ash'; do
    run() { NO_COLOR=1 $shell "$SCRIPT" -n -y "$@" </dev/null 2>&1 || true; }
    accepted() {
        out="$(run "$@")"
        case "$out" in
            *'Stage 0'*) : ;;
            *) fail "[$shell] arguments refused: $* -> $out" ;;
        esac
    }
    refused() {
        msg="$1"; shift
        out="$(run "$@")"
        case "$out" in
            *'Stage 0'*) fail "[$shell] accepted, expected '$msg': $*" ;;
            *"$msg"*) : ;;
            *) fail "[$shell] expected '$msg' for $*, got: $out" ;;
        esac
    }

    accepted --status-version v6.5.2
    printf '[status-version]\nv6.5.2\n' > "$TMP/status.conf"
    accepted --config "$TMP/status.conf"
    refused 'invalid status version' --status-version 6.5

    # one name, several addresses - and the clash the check is there for
    accepted --dns-host nas=303:1::1 --dns-host nas=303:1::2
    refused 'is given twice' --dns-host router=303:1::1

    refused 'invalid interface name' --iface 'ygg 0'
    refused 'invalid interface name' --lan 'lan|x'
    refused '--wait needs a number' --wait 1m
    accepted --iface ygg_1 --lan lan --wait 30
done

# Peer URIs reach the diagnostics only without their secrets.
extract_function() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\)" { found = 1 }
        found { print }
        found && /^}$/ { exit }
    ' "$SCRIPT"
}
eval "$(extract_function peer_shown)"
eval "$(extract_function add_peer)"
[ "$(peer_shown 'tls://h.example:443')" = 'tls://h.example:443' ] || fail 'plain URI changed'
[ "$(peer_shown 'tls://h.example:443?password=hunter2')" = 'tls://h.example:443?...' ] || fail 'query shown'
[ "$(peer_shown 'socks://u:hunter2@proxy:1080/h.example:443')" = 'socks://...@proxy:1080/h.example:443' ] || fail 'userinfo shown'
DIED=''
die() { DIED="$*"; }
PEERS=''
add_peer 'tlz://h.example:443?password=hunter2'
case "$DIED" in *hunter2*) fail "secret in an error message: $DIED" ;; '') fail 'bad scheme accepted' ;; esac
DIED=''; PEERS=''
add_peer 'tls://h.example:443'
add_peer 'tls://h.example:443'
[ "$PEERS" = 'tls://h.example:443' ] || fail "repeated peer kept twice: $PEERS"

# A trusted rule whose src_ip list could not be written must end the run: its
# old list is already deleted, and the rule alone would accept every node.
eval "$(extract_function uci_del)"
eval "$(extract_function uci_add_list)"
eval "$(extract_function fw_rule_trusted)"
DRY_RUN=0; DIED=''
TRUSTED='201:1111::1
202:2222::2'
uci() { case "$1" in add_list) return 1 ;; esac; return 0; }
fw_rule_trusted ygg_trusted_lan
case "$DIED" in *'unrestricted ACCEPT'*) : ;; *) fail "failed src_ip write did not stop the run: [$DIED]" ;; esac
ADDED="$TMP/added"; : > "$ADDED"; DIED=''
uci() { case "$1" in add_list) printf '%s\n' "$2" >> "$ADDED" ;; esac; return 0; }
fw_rule_trusted ygg_trusted_lan
[ -z "$DIED" ] || fail "fw_rule_trusted died on success: $DIED"
[ "$(cat "$ADDED")" = "firewall.ygg_trusted_lan.src_ip=201:1111::1
firewall.ygg_trusted_lan.src_ip=202:2222::2" ] || fail "src_ip list: $(cat "$ADDED")"

printf 'deployer command-line checks passed\n'
