# The btrfs default subvolume set to the root subvolume: where snapper cannot
# see the kernel command line (--root, a booted snapshot) the system may boot
# by the default id as well as by name. After the rename the default must
# name the new root, so the system boots it both ways: the rollback is checked
# after a reboot without subvol= on the kernel command line.
echo "=== the btrfs default subvolume follows the renamed root ==="
ensure_config

ROOT_ID=$(btrfs inspect-internal rootid /)
btrfs subvolume set-default "$ROOT_ID" /
PRE=$(snapper --no-dbus -c root create -d "default-follows-target" -p)
emit_marker          # created AFTER $PRE, so the rollback removes it
snapper --no-dbus -c root rollback "$PRE"

T=$(toplevel_mount)
NEW_ID=$(btrfs inspect-internal rootid "$T/$SUBVOL_NAME")
toplevel_umount "$T"
DEFAULT=$(btrfs subvolume get-default / | awk '{print $2}')
echo "new root $NEW_ID, default $DEFAULT"
[ "$DEFAULT" = "$NEW_ID" ] || { echo "FAIL: the default subvolume still names the old root"; exit 1; }

# boot by the default id only
for f in $(boot_entries); do
    [ -f "$f" ] && sed -i -E 's/[[:space:]]rootflags=subvol=[^[:space:]]*//g' "$f"
done
! grep -q 'rootflags=subvol=' $(boot_entries) || { echo "FAIL: setup: subvol= still in a boot entry"; exit 1; }
echo "booting without subvol=, engine verifies the marker is gone after reboot"
