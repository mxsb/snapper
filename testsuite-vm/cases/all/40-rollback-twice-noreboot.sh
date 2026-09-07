# Two rollbacks with no reboot in between must not corrupt the system: the second
# rollback completes, snapper stays usable, and after the reboot the system is on
# the rolled-back target (the post-target marker is gone). On subvol-rename this
# exercises the stale-running-root path (after the first rollback the running root
# has been renamed to <subvol>.rollback.N); if snapper mishandles it, this case
# fails and surfaces a real footgun.
echo "=== two rollbacks without a reboot between ($ROLLBACK_METHOD) ==="
ensure_config

PRE=$(snapper --no-dbus -c root create -d "twice-target" -p)
echo "target snapshot: $PRE"
emit_marker

echo "--- first rollback ---"
snapper --no-dbus -c root rollback "$PRE"
snapper --no-dbus -c root list >/dev/null || { echo "FAIL: snapper unusable after first rollback"; exit 1; }

echo "--- second rollback (no reboot in between) ---"
snapper --no-dbus -c root rollback "$PRE"
snapper --no-dbus -c root list >/dev/null || { echo "FAIL: snapper unusable after second rollback"; exit 1; }

echo "two rollbacks done; engine verifies the marker is gone after reboot"
