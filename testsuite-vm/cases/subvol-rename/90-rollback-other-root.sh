# snapper --root rolls back the system mounted at that path (e.g. from a rescue
# system), not the running one: the root subvolume, its btrfs top-level and the
# boot configuration must all be taken from the target.
echo "=== rollback of a system mounted at another root ==="
ensure_config

IMG=/root/other-root.img TOP=/mnt/other-top TARGET=/mnt/other-root
truncate -s 1G "$IMG"
LOOP=$(losetup --find --show "$IMG")
mkfs.btrfs -q -f "$LOOP"
mkdir -p "$TOP" "$TARGET"
mount "$LOOP" "$TOP"
btrfs subvolume create "$TOP/root2"
mount -o subvol=root2 "$LOOP" "$TARGET"

# a minimal target: fstab mounting root2 by name and a snapper config "other"
# for it, set up by hand since create-config with --root creates .snapshots in
# the running system
mkdir -p "$TARGET/etc/sysconfig" "$TARGET/etc/snapper/configs"
echo "$LOOP / btrfs subvol=root2 0 0" > "$TARGET/etc/fstab"
echo 'SNAPPER_CONFIGS="other"' > "$TARGET/etc/sysconfig/snapper"
TEMPLATE=/etc/snapper/config-templates/default
[ -f "$TEMPLATE" ] || TEMPLATE=/usr/share/snapper/config-templates/default
sed 's/^SUBVOLUME=.*/SUBVOLUME="\/"/' "$TEMPLATE" > "$TARGET/etc/snapper/configs/other"
btrfs subvolume create "$TARGET/.snapshots"

echo target-before > "$TARGET/target-marker"
PRE=$(snapper --no-dbus --root "$TARGET" -c other create -d "other-root-target" -p)
echo target-after > "$TARGET/target-marker"

HOST_ROOT_ID=$(btrfs inspect-internal rootid /)
OUT=$(snapper --no-dbus --root "$TARGET" -c other rollback "$PRE" 2>&1) && RC=0 || RC=$?
echo "$OUT"
[ $RC -eq 0 ] || { echo "FAIL: rollback at --root $TARGET failed"; exit 1; }

echo "--- target top-level after the rollback ---"; ls "$TOP"
ls -d "$TOP"/root2.rollback.* >/dev/null 2>&1 \
    || { echo "FAIL: root2 of the target was not replaced"; exit 1; }
[ "$(cat "$TOP/root2/target-marker")" = target-before ] \
    || { echo "FAIL: target root2 does not hold snapshot $PRE"; exit 1; }

H=$(toplevel_mount)
if ls -d "$H/$SUBVOL_NAME".rollback.* >/dev/null 2>&1 \
   || [ "$(btrfs inspect-internal rootid "$H/$SUBVOL_NAME")" != "$HOST_ROOT_ID" ]; then
    toplevel_umount "$H"; echo "FAIL: the running system's root was touched"; exit 1
fi
toplevel_umount "$H"

umount -R "$TARGET"; umount "$TOP"; losetup -d "$LOOP"
echo "target root2 replaced, running system untouched"
