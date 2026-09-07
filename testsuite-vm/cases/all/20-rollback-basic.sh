# A rollback to an explicit snapshot must take effect after reboot: a marker
# created after the target snapshot is gone once the system boots the rollback.
echo "=== basic rollback ($ROLLBACK_METHOD) ==="
ensure_config

PRE=$(snapper --no-dbus -c root create -d "basic-rollback-target" -p)
echo "target snapshot: $PRE"
emit_marker          # created AFTER $PRE, so a correct rollback removes it

OUT=$(snapper --no-dbus -c root rollback "$PRE" 2>&1)
echo "$OUT"
# No spurious "will not take effect" warning on the default (auto) rollback.
# (Explicit if: a bare "! ... | grep" would not fail the case under set -e.)
if echo "$OUT" | grep -q "will not take effect"; then
    echo "FAIL: unexpected 'will not take effect' warning on default rollback"; exit 1
fi
echo "rollback issued; engine will verify the marker is gone after reboot"
