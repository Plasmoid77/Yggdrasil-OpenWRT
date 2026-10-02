#!/bin/sh
# shellcheck disable=SC2016
# The status installer, run as shipped (a release directory named
# yggdrasil-status-<version>) into a scratch root through DESTDIR: a fresh
# install, an upgrade with its backup, and the rollback when a copy or the
# rpcd validation fails. id, ubus, arping and sleep are stubs on PATH; cp
# is the real one, except that it refuses the first copy to FAIL_CP. The
# installer runs under /bin/sh: a BusyBox ash that prefers its applets
# would bypass the id and cp stubs.
set -u
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
eq() { [ "$1" = "$2" ] || fail "expected [$1], got [$2]"; }

PKG="$TMP/yggdrasil-status-7.0"
cp -R "$ROOT/source/yggdrasil-status" "$PKG"
# modes as a lossy unpack leaves them: the installer must set its own
chmod 644 "$PKG/root/usr/libexec/rpcd/luci.yggdrasil-status"
chmod 600 "$PKG/www/luci-static/resources/view/status/yggdrasil.js"
BIN="$TMP/bin"; mkdir -p "$BIN"
printf '#!/bin/sh\necho 0\n' > "$BIN/id"
printf '#!/bin/sh\nexit 0\n' > "$BIN/sleep"
printf '#!/bin/sh\nexit 0\n' > "$BIN/arping"
cat > "$BIN/cp" <<EOF
#!/bin/sh
for last; do :; done
if [ -n "\${FAIL_CP:-}" ] && [ "\$last" = "\$FAIL_CP" ] && [ ! -e '$TMP/cp-failed' ]; then
    : > '$TMP/cp-failed'; exit 1
fi
PATH="\${PATH#*:}" exec cp "\$@"
EOF
cat > "$BIN/ubus" <<'EOF'
#!/bin/sh
case "$1 $2" in
    'list ') echo network; echo luci.yggdrasil-status ;;
    '-v list') echo '"luci.yggdrasil-status" @1 {'; [ "${UBUS_NO_PIN:-0}" = 1 ] || echo '"pin":{}'; echo '"unpin":{}' ;;
    'call luci.yggdrasil-status') echo '{"clients":[]}' ;;
    *) exit 1 ;;
esac
EOF
chmod 755 "$BIN"/*

BACKEND=usr/libexec/rpcd/luci.yggdrasil-status
ACL=usr/share/rpcd/acl.d/yggdrasil-status.json
MENU=usr/share/luci/menu.d/yggdrasil-status.json
VIEW=www/luci-static/resources/view/status/yggdrasil.js

fresh_root() {   # $1 = name; a router root with only rpcd's init script
    DEST="$TMP/$1"; rm -f "$TMP/cp-failed"
    mkdir -p "$DEST/etc/init.d" "$DEST/tmp" "$DEST/root"
    printf '#!/bin/sh\necho "rpcd $1" >> "%s/rpcd.log"\n' "$DEST" > "$DEST/etc/init.d/rpcd"
    chmod 755 "$DEST/etc/init.d/rpcd"
    : > "$DEST/tmp/luci-indexcache"
}
old_files() {    # the previous release: every file present with old content
    for f in $BACKEND $ACL $MENU $VIEW; do
        mkdir -p "$DEST/$(dirname "$f")"
        echo "old $f" > "$DEST/$f"
    done
}
install() {      # runs the shipped installer; output in $OUT, status in $RC
    OUT="$(DESTDIR="$DEST" PATH="$BIN:$PATH" /bin/sh "$PKG/install.sh" 2>&1)"; RC=$?
}
same_as_package() {
    cmp -s "$PKG/root/$BACKEND" "$DEST/$BACKEND" && cmp -s "$PKG/root/$ACL" "$DEST/$ACL" &&
        cmp -s "$PKG/root/$MENU" "$DEST/$MENU" && cmp -s "$PKG/$VIEW" "$DEST/$VIEW"
}
mode() { stat -c %a "$1"; }
COUNT=0
run() { COUNT=$((COUNT + 1)); ( "$2" ) || fail "$1"; printf 'PASS: %s\n' "$1"; }

fresh_install() {
    fresh_root fresh
    install
    eq 0 "$RC"
    same_as_package || fail 'installed files differ from the package'
    eq 755 "$(mode "$DEST/$BACKEND")"
    eq 644 "$(mode "$DEST/$VIEW")"
    [ ! -e "$DEST/tmp/luci-indexcache" ] || fail 'LuCI index cache left in place'
    eq 'rpcd restart' "$(cat "$DEST/rpcd.log")"
    case "$OUT" in *' Yggdrasil Status 7.0 installed'*) : ;; *) fail "no version line: $OUT" ;; esac
    backup="$(ls -d "$DEST"/root/yggdrasil-status-backup-*)"
    eq '' "$(cat "$backup/present.list")"
}

upgrade_backup() {
    fresh_root upgrade; old_files
    install
    eq 0 "$RC"
    same_as_package || fail 'upgrade did not install the package files'
    backup="$(ls -d "$DEST"/root/yggdrasil-status-backup-*)"
    eq "old $BACKEND" "$(cat "$backup/$BACKEND")"
    eq "old $VIEW" "$(cat "$backup/$VIEW")"
    eq 4 "$(wc -l < "$backup/present.list" | tr -d ' ')"
    grep -Fxq "$DEST/$MENU" "$backup/present.list" || fail 'present.list does not name the menu file'
}

copy_rollback() {
    # the third copy fails (a full overlay): the old release comes back whole
    fresh_root copyfail; old_files
    export FAIL_CP="$DEST/$MENU"; install; unset FAIL_CP
    eq 1 "$RC"
    for f in $BACKEND $ACL $MENU $VIEW; do eq "old $f" "$(cat "$DEST/$f")"; done
    case "$OUT" in *'restoring previous status module'*) : ;; *) fail "no rollback message: $OUT" ;; esac
    eq 'rpcd restart' "$(cat "$DEST/rpcd.log")"
    # on a first install the half-copied files are removed, not left mixed
    fresh_root copyfail-fresh
    export FAIL_CP="$DEST/$VIEW"; install; unset FAIL_CP
    eq 1 "$RC"
    for f in $BACKEND $ACL $MENU $VIEW; do [ ! -e "$DEST/$f" ] || fail "left behind: $f"; done
}

validation_rollback() {
    # rpcd comes back without the pin method: the old release returns
    fresh_root novalid; old_files
    export UBUS_NO_PIN=1; install; unset UBUS_NO_PIN
    eq 1 "$RC"
    for f in $BACKEND $ACL $MENU $VIEW; do eq "old $f" "$(cat "$DEST/$f")"; done
    eq "$(printf 'rpcd restart\nrpcd restart')" "$(cat "$DEST/rpcd.log")"
}

checkout_label() {
    # a git checkout has no version in its directory name
    fresh_root checkout
    OUT="$(DESTDIR="$DEST" PATH="$BIN:$PATH" /bin/sh "$ROOT/source/yggdrasil-status/install.sh" 2>&1)" || fail "checkout install failed: $OUT"
    case "$OUT" in *' Yggdrasil Status installed'*) : ;; *) fail "unexpected label: $OUT" ;; esac
}

run 'fresh install: package files, modes, index cache, rpcd restart, version line' fresh_install
run 'upgrade: the previous files are backed up and listed' upgrade_backup
run 'a failed copy restores the previous release or removes a partial first install' copy_rollback
run 'a failed rpcd validation restores the previous release' validation_rollback
run 'a checkout install is labelled without a version' checkout_label
printf '%s installer groups passed\n' "$COUNT"
