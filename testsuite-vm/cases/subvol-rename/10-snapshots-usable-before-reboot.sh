# On a named-subvolume layout the rollback moves the nested .snapshots subvolume
# into the new root; the D fix re-mounts it on the still-running old root so
# snapper keeps working before the reboot. Verify list + create/delete work.
echo "=== /.snapshots usable before reboot after subvol-rename rollback ==="
ensure_config

PRE=$(snapper --no-dbus -c root create -d "snapshots-usable-target" -p)
emit_marker
snapper --no-dbus -c root rollback "$PRE"

echo "--- findmnt /.snapshots ---"; findmnt /.snapshots || echo "(/.snapshots is not a separate mount)"
echo "--- /.snapshots contents ---"; ls -la /.snapshots 2>&1 || true
snapper --no-dbus -c root list
ls /.snapshots/*/info.xml >/dev/null 2>&1 \
    || { echo "FAIL: no snapshots visible under /.snapshots after rollback (before reboot)"; exit 1; }

echo "--- create + delete a snapshot on the re-mounted .snapshots ---"
NEW=$(snapper --no-dbus -c root create -d "post-rollback-write" -p)
test -e "/.snapshots/$NEW/info.xml" || { echo "FAIL: created snapshot $NEW not visible under /.snapshots"; exit 1; }
snapper --no-dbus -c root delete "$NEW"
! test -e "/.snapshots/$NEW/info.xml" || { echo "FAIL: snapshot $NEW still present after delete"; exit 1; }

echo "Snapper create/delete works on the re-mounted .snapshots before reboot."
