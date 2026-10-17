# On subvol-rename the btrfs default subvolume has no role at boot. When it
# points at an old snapshot (e.g. left by an earlier set-default rollback), a
# rollback must neither label its backup with that snapshot nor give it a
# cleanup algorithm (classic does both for the previous default snapshot, which
# number cleanup then deletes).
echo "=== rollback with the btrfs default at an unrelated snapshot ==="
ensure_config

OLD=$(snapper --no-dbus -c root create -d "unrelated-old-default" -p)
OLD_ID=$(btrfs inspect-internal rootid "/.snapshots/$OLD/snapshot")
T=$(toplevel_mount)
btrfs subvolume set-default "$OLD_ID" "$T"
DEFAULT=$(btrfs subvolume get-default "$T" | awk '{print $2}')
toplevel_umount "$T"
[ "$DEFAULT" = "$OLD_ID" ] || { echo "FAIL: setup: btrfs default is $DEFAULT, not #$OLD ($OLD_ID)"; exit 1; }

PRE=$(snapper --no-dbus -c root create -d "untouched-target" -p)
OUT=$(snapper --no-dbus -c root rollback "$PRE" 2>&1)
echo "$OUT"
BACKUP=$(echo "$OUT" | sed -n 's/.*read-only snapshot.*(Snapshot \([0-9]*\)\.).*/\1/p')

snapper --no-dbus -c root list
DESC=$(snapper --no-dbus -c root --csvout list --columns number,description | awk -F, -v n="$BACKUP" '$1==n {print $2}')
CLEANUP=$(snapper --no-dbus -c root --csvout list --columns number,cleanup | awk -F, -v n="$OLD" '$1==n {print $2}')
echo "backup #$BACKUP: '$DESC'; unrelated #$OLD cleanup: '$CLEANUP'"

case "$DESC" in
    *"of #$OLD"*) echo "FAIL: backup #$BACKUP is labelled with the unrelated #$OLD"; exit 1 ;;
esac
[ -z "$CLEANUP" ] || { echo "FAIL: unrelated snapshot #$OLD got cleanup '$CLEANUP'"; exit 1; }
echo "unrelated default snapshot untouched"
