# Under SELinux enforcing, the subvol-rename rollback re-mounts .snapshots on the
# running root; verify it stays accessible and correctly labelled.
requires selinux
echo "=== rollback under SELinux enforcing ==="
ensure_config

setenforce 1
test "$(getenforce)" = "Enforcing" || { echo "FAIL: could not set enforcing"; exit 1; }
echo "--- /.snapshots label before ---"; ls -Zd /.snapshots

PRE=$(snapper --no-dbus -c root create -d "selinux-target" -p)
snapper --no-dbus -c root rollback "$PRE"

echo "--- /.snapshots after (re-mounted) ---"; findmnt /.snapshots; ls -Zd /.snapshots
snapper --no-dbus -c root list >/dev/null \
    || { echo "FAIL: snapper list fails under SELinux enforcing after rollback"; exit 1; }

NEW=$(snapper --no-dbus -c root create -d "selinux-write" -p)
test -e "/.snapshots/$NEW/info.xml" || { echo "FAIL: created snapshot not visible under enforcing"; exit 1; }
snapper --no-dbus -c root delete "$NEW"

if command -v ausearch >/dev/null 2>&1; then
    ausearch -m avc -ts recent 2>/dev/null | grep -i snapshot \
        && echo "WARN: snapshot AVC denials (see above)" || echo "no snapshot AVC denials"
fi
echo "OK: rollback works under SELinux enforcing"
