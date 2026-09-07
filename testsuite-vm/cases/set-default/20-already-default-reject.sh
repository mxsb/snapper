# Rolling back to the snapshot that is already the active default must be
# rejected (the transactional path checks active == default).
echo "=== rollback to the active default snapshot is rejected ==="
ensure_config

DEFAULT_PATH=$(btrfs subvolume get-default / | sed 's/.*path //')
DEFN=$(echo "$DEFAULT_PATH" | sed -n 's|.*\.snapshots/\([0-9]*\)/snapshot$|\1|p')
if [ -z "$DEFN" ]; then echo "SKIP: default subvolume is not a snapper snapshot"; exit 0; fi
echo "active default snapshot: $DEFN"

# Read-only default => transactional ambit, where the active==default check lives.
btrfs property set "/.snapshots/$DEFN/snapshot" ro true
if OUT=$(snapper --no-dbus -c root rollback "$DEFN" 2>&1); then
    echo "$OUT"
    echo "FAIL: rollback to the active default snapshot did not fail"
    btrfs property set "/.snapshots/$DEFN/snapshot" ro false; exit 1
fi
echo "$OUT"
echo "$OUT" | grep -q "already default" \
    || { echo "FAIL: expected the 'already default' rejection"; btrfs property set "/.snapshots/$DEFN/snapshot" ro false; exit 1; }
btrfs property set "/.snapshots/$DEFN/snapshot" ro false
echo "OK: rollback to the active default snapshot is rejected"
