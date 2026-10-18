# After the exchange the placeholders of empty nested subvolumes are removed
# from the new root, best effort. A failure must be reported to the user, not
# only logged: here the parent directory is immutable in the target snapshot
# (the snapshot keeps the inode flags), so rmdir fails with EPERM.
echo "=== a placeholder that cannot be removed is reported ==="
ensure_config

mkdir -p /nested-test
btrfs subvolume create /nested-test/sub
chattr +i /nested-test
PRE=$(snapper --no-dbus -c root create -d "placeholder-warning-target" -p)
chattr -i /nested-test

OUT=$(snapper --no-dbus -c root rollback "$PRE" 2>&1) && rc=0 || rc=$?
echo "$OUT"
[ "$rc" -eq 0 ] || { echo "FAIL: the rollback failed"; exit 1; }
echo "$OUT" | grep -q '^Warning: .*nested-test/sub' \
    || { echo "FAIL: no warning about the placeholder nested-test/sub"; exit 1; }

T=$(toplevel_mount)
chattr -i "$T/$SUBVOL_NAME/nested-test" || true
toplevel_umount "$T"
echo "OK: the failed placeholder removal is reported"
