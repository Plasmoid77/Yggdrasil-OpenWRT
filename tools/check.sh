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
sh tests/status-inventory.sh
busybox ash tests/status-inventory.sh
sh tests/status-download.sh
busybox ash tests/status-download.sh
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
