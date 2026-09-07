# `snapper rollback` with no argument rolls the current system back to a fresh
# writable copy of the current state (a read-only snapshot of the default plus a
# read-write snapshot of current, which becomes the new default). Data is
# preserved, so a marker created beforehand must SURVIVE the reboot, and the
# system must boot on the new default.
echo "=== no-argument rollback ($ROLLBACK_METHOD) ==="
ensure_config

emit_persist_marker   # must still exist after reboot (no-arg preserves data)

OUT=$(snapper --no-dbus -c root rollback 2>&1)
echo "$OUT"
echo "$OUT" | grep -q "Creating read-only snapshot of default subvolume." \
    || { echo "FAIL: no-arg rollback did not create the read-only snapshot of the default"; exit 1; }
echo "$OUT" | grep -q "Setting default subvolume" \
    || { echo "FAIL: no-arg rollback did not set a new default subvolume"; exit 1; }

snapper --no-dbus -c root list >/dev/null || { echo "FAIL: snapper unusable after no-arg rollback"; exit 1; }
echo "no-arg rollback issued; engine will verify the marker survives the reboot"
