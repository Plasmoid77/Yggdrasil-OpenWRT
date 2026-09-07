#!/bin/sh
# shellcheck disable=SC3043
# Target shell is BusyBox ash on OpenWrt: SC3043 ('local' is undefined in
# POSIX sh) does not apply.
set -eu

[ "$(id -u)" -eq 0 ] || {
	echo 'ERROR: run this installer as root' >&2
	exit 1
}

BASE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
BACKUP="/root/yggdrasil-status-backup-$(date +%Y%m%d-%H%M%S)"

BACKEND_SRC="$BASE/root/usr/libexec/rpcd/luci.yggdrasil-status"
ACL_SRC="$BASE/root/usr/share/rpcd/acl.d/yggdrasil-status.json"
MENU_SRC="$BASE/root/usr/share/luci/menu.d/yggdrasil-status.json"
VIEW_SRC="$BASE/www/luci-static/resources/view/status/yggdrasil.js"

BACKEND_DST='/usr/libexec/rpcd/luci.yggdrasil-status'
ACL_DST='/usr/share/rpcd/acl.d/yggdrasil-status.json'
MENU_DST='/usr/share/luci/menu.d/yggdrasil-status.json'
VIEW_DST='/www/luci-static/resources/view/status/yggdrasil.js'

for f in "$BACKEND_SRC" "$ACL_SRC" "$MENU_SRC" "$VIEW_SRC"; do
	[ -f "$f" ] || {
		echo "ERROR: package file missing: $f" >&2
		exit 1
	}
done

sh -n "$BACKEND_SRC" || {
	echo 'ERROR: backend syntax check failed before installation' >&2
	exit 1
}

mkdir -p "$BACKUP"
: > "$BACKUP/present.list"

backup_one() {
	local src="$1"
	local rel="${src#/}"

	if [ -f "$src" ]; then
		mkdir -p "$BACKUP/$(dirname "$rel")"
		cp -a "$src" "$BACKUP/$rel"
		printf '%s\n' "$src" >> "$BACKUP/present.list"
	fi
}

restore_one() {
	local dst="$1"
	local rel="${dst#/}"

	if grep -Fxq "$dst" "$BACKUP/present.list" 2>/dev/null; then
		mkdir -p "$(dirname "$dst")"
		cp -a "$BACKUP/$rel" "$dst"
	else
		rm -f "$dst"
	fi
}

rollback() {
	echo 'ERROR: validation failed; restoring previous status module' >&2
	restore_one "$BACKEND_DST"
	restore_one "$ACL_DST"
	restore_one "$MENU_DST"
	restore_one "$VIEW_DST"
	rm -f /tmp/luci-indexcache
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	echo "Rollback restored from: $BACKUP" >&2
	exit 1
}

for f in "$BACKEND_DST" "$ACL_DST" "$MENU_DST" "$VIEW_DST"; do
	backup_one "$f"
done

if ! command -v arping >/dev/null 2>&1; then
	command -v apk >/dev/null 2>&1 || {
		echo 'ERROR: arping is missing and apk is unavailable' >&2
		exit 1
	}
	apk add iputils-arping
fi

mkdir -p \
	"$(dirname "$BACKEND_DST")" \
	"$(dirname "$ACL_DST")" \
	"$(dirname "$MENU_DST")" \
	"$(dirname "$VIEW_DST")"

cp "$BACKEND_SRC" "$BACKEND_DST"
cp "$ACL_SRC" "$ACL_DST"
cp "$MENU_SRC" "$MENU_DST"
cp "$VIEW_SRC" "$VIEW_DST"
chmod 0755 "$BACKEND_DST"
chmod 0644 "$ACL_DST" "$MENU_DST" "$VIEW_DST"

sh -n "$BACKEND_DST" || rollback

rm -f /tmp/luci-indexcache
/etc/init.d/rpcd restart || rollback
sleep 2

ubus list | grep -qx 'luci.yggdrasil-status' || rollback

SIGNATURE="$(ubus -v list luci.yggdrasil-status 2>/dev/null)" || rollback
printf '%s\n' "$SIGNATURE" | grep -q '"pin"' || rollback
printf '%s\n' "$SIGNATURE" | grep -q '"unpin"' || rollback

RESULT="$(ubus call luci.yggdrasil-status clients 2>/dev/null)" || rollback
[ -n "$RESULT" ] || rollback

printf '%s\n' '============================================================'
printf '%s\n' ' Yggdrasil Status v5 installed'
printf '%s\n' '============================================================'
printf 'Backup: %s\n' "$BACKUP"
printf '%s\n' ''
printf '%s\n' 'Current RPC result:'
printf '%s\n' "$RESULT"
printf '%s\n' ''
printf '%s\n' 'No network reload or firewall restart was performed.'
