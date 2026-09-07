# When the <subvol>.rollback.<N> backup name already exists, the rollback must
# fall back to a subvolume-id-based name (<subvol>.rollback.svid.<id>).
echo "=== repeated rollback: .rollback.svid fallback on name collision ==="
ensure_config

PRE=$(snapper --no-dbus -c root create -d "svid-target" -p)
emit_marker

# The rollback names its backup <subvol>.rollback.<N>, where N is the number of
# the read-write copy it creates (rw current = PRE+1, rw copy of PRE = PRE+2).
# Pre-create that exact name to force the subvolume-id fallback.
NEXT=$((PRE + 2))
T=$(toplevel_mount)
btrfs subvolume create "$T/$SUBVOL_NAME.rollback.$NEXT"

snapper --no-dbus -c root rollback "$PRE"

echo "--- backups after rollback ---"; ls -d "$T/$SUBVOL_NAME".rollback.* 2>/dev/null || true
if ! ls -d "$T/$SUBVOL_NAME".rollback.svid.* >/dev/null 2>&1; then
    echo "FAIL: expected a $SUBVOL_NAME.rollback.svid.<id> fallback backup"
    toplevel_umount "$T"; exit 1
fi
echo "svid fallback backup present: $(ls -d "$T/$SUBVOL_NAME".rollback.svid.*)"
toplevel_umount "$T"
echo "engine verifies the marker is gone after reboot"
