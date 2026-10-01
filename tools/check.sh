#!/bin/sh
# Host-side checks only. Never invoke either router installer here.
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
for tool in git python3 node jq busybox sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing host dependency: $tool" >&2; exit 1; }
done
if [ "${SKIP_SHELLCHECK:-0}" = 1 ]; then
    echo 'WARNING: ShellCheck explicitly skipped; this is a partial local check.' >&2
else
    command -v shellcheck >/dev/null 2>&1 || { echo 'Missing host dependency: shellcheck' >&2; exit 1; }
fi

git ls-files | while IFS= read -r file; do
    case "$file" in
        *.sh|*/luci.yggdrasil-status|*/yggdrasil-split-dns)
            sh -n "$file"
            busybox ash -n "$file"
            if [ "${SKIP_SHELLCHECK:-0}" != 1 ]; then shellcheck -s sh "$file"; fi ;;
        *.json) jq empty "$file" ;;
        *.js) node --check "$file" ;;
    esac
done

sh tests/deploy-secret-handling.sh
busybox ash tests/deploy-secret-handling.sh
sh tests/deploy-peers-optional.sh
busybox ash tests/deploy-peers-optional.sh
sh tests/deploy-config-file.sh
busybox ash tests/deploy-config-file.sh
sh tests/deploy-lan-overlay.sh
busybox ash tests/deploy-lan-overlay.sh
sh tests/deploy-hotplug-guard.sh
busybox ash tests/deploy-hotplug-guard.sh
sh tests/deploy-dns-names.sh
busybox ash tests/deploy-dns-names.sh
sh tests/deploy-peer-hook.sh
busybox ash tests/deploy-peer-hook.sh
sh tests/deploy-keep-edge.sh
busybox ash tests/deploy-keep-edge.sh
sh tests/deploy-cli.sh
busybox ash tests/deploy-cli.sh
sh tests/status-inventory.sh
busybox ash tests/status-inventory.sh
sh tests/status-download.sh
busybox ash tests/status-download.sh
# The router runs BusyBox's awk, sed, grep and friends, not the host's gawk or
# GNU tools: run the shell tests once more with those applets first on PATH.
APPLETS="$(mktemp -d)"
trap 'rm -rf "$APPLETS"' EXIT HUP INT TERM
applets='sed tr grep cut head tail date sort uniq wc'
# OpenWrt builds BusyBox awk with math (^, exp); some distribution builds,
# Ubuntu's among them, do not and would fail where the router works.
if busybox awk 'BEGIN { exit !(2 ^ 3 == 8) }' 2>/dev/null; then
    applets="awk $applets"
else
    echo 'NOTE: this BusyBox awk has no math support; the applet pass keeps the host awk.' >&2
fi
for applet in $applets; do
    printf '#!/bin/sh\nexec busybox %s "$@"\n' "$applet" > "$APPLETS/$applet"
    chmod +x "$APPLETS/$applet"
done
for test in tests/deploy-*.sh tests/status-inventory.sh; do
    PATH="$APPLETS:$PATH" busybox ash "$test" >/dev/null \
        || { echo "FAIL with BusyBox applets: $test" >&2; exit 1; }
done
python3 tests/repository.py
(
    cd packages
    for checksum in *.tar.gz.sha256; do sha256sum -c "$checksum"; done
)
if [ "${SKIP_SHELLCHECK:-0}" = 1 ]; then
    echo 'Local checks passed with ShellCheck explicitly skipped; require full CI before merge.'
else
    echo 'All host-side checks passed. Router validation is separate.'
fi
