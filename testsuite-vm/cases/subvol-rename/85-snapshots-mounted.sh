# .snapshots nested in the root and also mounted (e.g. by an fstab line for
# it): a mount point cannot be renamed (EBUSY), so .snapshots cannot move into
# the new root. The rollback must be refused with the root untouched, instead
# of booting a new root without .snapshots.
echo "=== rollback with the nested .snapshots mounted ==="
ensure_config

PRE=$(snapper --no-dbus -c root create -d "snapshots-mounted-target" -p)
ROOT_ID=$(btrfs inspect-internal rootid /)
mount --bind /.snapshots /.snapshots

OUT=$(snapper --no-dbus -c root rollback "$PRE" 2>&1) && rc=0 || rc=$?
echo "$OUT"
umount /.snapshots || true

[ "$rc" -ne 0 ] || { echo "FAIL: the rollback was not refused"; exit 1; }
echo "$OUT" | grep -q '\.snapshots' || { echo "FAIL: the refusal does not name .snapshots"; exit 1; }

T=$(toplevel_mount)
fail=""
[ "$(btrfs inspect-internal rootid "$T/$SUBVOL_NAME")" = "$ROOT_ID" ] || fail="the root subvolume was replaced"
[ ! -e "$T/$SUBVOL_NAME.incoming" ] || fail="$SUBVOL_NAME.incoming was left behind"
[ "$(stat -c %i "$T/$SUBVOL_NAME/.snapshots" 2>/dev/null)" = 256 ] || fail=".snapshots is no longer in the root"
toplevel_umount "$T"
[ -z "$fail" ] || { echo "FAIL: $fail"; exit 1; }

snapper --no-dbus -c root --csvout list --columns number | grep -qx "$PRE" \
    || { echo "FAIL: snapper no longer lists snapshot $PRE"; exit 1; }
echo "refused, root and .snapshots untouched"
