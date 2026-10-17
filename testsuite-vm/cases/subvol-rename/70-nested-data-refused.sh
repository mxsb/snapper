# A subvolume nested in the root subvolume that holds data would only be
# reachable in the old root after a rollback (a snapshot does not include it),
# so the rollback must be refused before anything is changed.
echo "=== nested subvolume with data refuses the rollback ==="
ensure_config

btrfs subvolume create /nested-diag
echo data > /nested-diag/diag-data

PRE=$(snapper --no-dbus -c root create -d "nested-data" -p)
BEFORE=$(snapper --no-dbus -c root --csvout list --columns number | tail -n +2 | sort -n | tr '\n' ' ')

if OUT=$(snapper --no-dbus -c root rollback "$PRE" 2>&1); then
    echo "$OUT"
    echo "FAIL: rollback succeeded although /nested-diag contains data"; exit 1
fi
echo "$OUT"
if ! echo "$OUT" | grep -q "nested-diag"; then
    echo "FAIL: refusal does not name nested-diag"; exit 1
fi

AFTER=$(snapper --no-dbus -c root --csvout list --columns number | tail -n +2 | sort -n | tr '\n' ' ')
if [ "$BEFORE" != "$AFTER" ]; then
    echo "FAIL: snapshots changed by the refused rollback: '$BEFORE' -> '$AFTER'"; exit 1
fi

T=$(toplevel_mount)
LEFT=$(ls -d "$T/$SUBVOL_NAME".incoming "$T/$SUBVOL_NAME".rollback.* 2>/dev/null || true)
toplevel_umount "$T"
if [ -n "$LEFT" ]; then
    echo "FAIL: refused rollback left subvolumes behind: $LEFT"; exit 1
fi

if [ "$(cat /nested-diag/diag-data)" != data ]; then
    echo "FAIL: /nested-diag data changed"; exit 1
fi
echo "rollback refused, nothing changed"
