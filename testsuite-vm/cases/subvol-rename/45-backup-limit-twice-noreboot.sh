# With ROLLBACK_BACKUP_LIMIT=1 and two rollbacks without a reboot in between,
# the running system is the first rollback's backup, which is older than the
# second one's. The prune of the second rollback must not delete it, and the
# system must boot the second rollback.
echo "=== ROLLBACK_BACKUP_LIMIT=1, two rollbacks without a reboot ==="
ensure_config

CONF=/etc/snapper/configs/root
sed -i '/^ROLLBACK_BACKUP_LIMIT=/d' "$CONF"
echo 'ROLLBACK_BACKUP_LIMIT="1"' >> "$CONF"

RUNNING=$(btrfs inspect-internal rootid /)
PRE=$(snapper --no-dbus -c root create -d "limit-twice-target" -p)
emit_marker          # created AFTER $PRE, so the rollback removes it

snapper --no-dbus -c root rollback "$PRE"
snapper --no-dbus -c root rollback "$PRE"

T=$(toplevel_mount)
btrfs subvolume list "$T"
if ! btrfs subvolume list "$T" | awk '{print $2}' | grep -qx "$RUNNING"; then
    toplevel_umount "$T"
    echo "FAIL: the running root (subvolume $RUNNING) was pruned"; exit 1
fi
toplevel_umount "$T"
echo "running root $RUNNING kept; engine verifies the marker is gone after reboot"
