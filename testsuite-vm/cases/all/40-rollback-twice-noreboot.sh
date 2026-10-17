# Two rollbacks with no reboot in between, to different targets: the system must
# boot the second one. On subvol-rename the running root has been renamed to
# <subvol>.rollback.N by the first rollback, so the second must still replace the
# subvolume that boots, not the running one.
echo "=== two rollbacks without a reboot between ($ROLLBACK_METHOD) ==="
ensure_config

SECOND=/rollback-twice-second
rm -f "$SECOND"
PRE1=$(snapper --no-dbus -c root create -d "twice-target-1" -p)
echo "only in the second target" > "$SECOND"
PRE2=$(snapper --no-dbus -c root create -d "twice-target-2" -p)
echo "targets: $PRE1 (without $SECOND), $PRE2 (with it)"
emit_marker          # created after both targets: gone after the reboot

echo "--- first rollback, to $PRE1 ---"
snapper --no-dbus -c root rollback "$PRE1"
snapper --no-dbus -c root list >/dev/null || { echo "FAIL: snapper unusable after first rollback"; exit 1; }

echo "--- second rollback, to $PRE2 (no reboot in between) ---"
snapper --no-dbus -c root rollback "$PRE2"
snapper --no-dbus -c root list >/dev/null || { echo "FAIL: snapper unusable after second rollback"; exit 1; }

# booted the second target: its file is there
echo "PERSIST_MARKER=$SECOND"
echo "two rollbacks done; engine verifies the reboot lands on $PRE2"
