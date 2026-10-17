# A no-argument rollback backs up the current system. On subvol-rename the
# system boots the named root, not the btrfs default subvolume, which may point
# at an old snapshot (e.g. after an earlier classic rollback or snapper modify
# --default): the backup must still be of the running root.
echo "=== no-argument rollback with the btrfs default at an old snapshot ==="
ensure_config

OLD=$(snapper --no-dbus -c root create -d "old-default" -p)
T=$(toplevel_mount)
btrfs subvolume set-default "$(btrfs inspect-internal rootid "/.snapshots/$OLD/snapshot")" "$T"
toplevel_umount "$T"

echo "current state" > /noarg-current-marker
OUT=$(snapper --no-dbus -c root rollback 2>&1)
echo "$OUT"
BACKUP=$(echo "$OUT" | sed -n 's/.*read-only snapshot.*(Snapshot \([0-9]*\)\.).*/\1/p')
[ -n "$BACKUP" ] || { echo "FAIL: no backup snapshot reported"; exit 1; }

if [ ! -e "/.snapshots/$BACKUP/snapshot/noarg-current-marker" ]; then
    echo "FAIL: backup #$BACKUP is not of the running root (marker missing)"; exit 1
fi
echo "backup #$BACKUP holds the current state"
