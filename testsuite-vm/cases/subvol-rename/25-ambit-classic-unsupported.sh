# An explicit --ambit classic wins over the detection, also where the boot
# configuration makes the detection refuse (here fstab names another subvolume
# than the kernel command line): snapper warns with the reason and sets the
# default subvolume, as without the rename method.
echo "=== explicit --ambit classic where the detection refuses ==="
ensure_config

PRE=$(snapper --no-dbus -c root create -d "classic-unsupported-target" -p)
cp /etc/fstab /etc/fstab.orig
sed -i -E "/^[^#][^[:space:]]*[[:space:]]+\/[[:space:]]+btrfs/ s/subvol=\/?$SUBVOL_NAME([,[:space:]])/subvol=other-root\1/" /etc/fstab
awk '$2=="/"' /etc/fstab

# auto refuses
OUT=$(snapper --no-dbus -c root rollback "$PRE" 2>&1) && rc=0 || rc=$?
echo "$OUT"
[ "$rc" -ne 0 ] || { mv /etc/fstab.orig /etc/fstab; echo "FAIL: setup: auto did not refuse"; exit 1; }

# explicit classic runs
OUT=$(snapper --no-dbus --ambit classic -c root rollback -p "$PRE" 2>&1) && rc=0 || rc=$?
mv /etc/fstab.orig /etc/fstab
echo "$OUT"
[ "$rc" -eq 0 ] || { echo "FAIL: explicit --ambit classic was refused"; exit 1; }
echo "$OUT" | grep -q "^Warning: .*other-root" || { echo "FAIL: no warning with the reason"; exit 1; }
NEW=$(echo "$OUT" | tail -1)
DEFAULT=$(btrfs subvolume get-default / | awk '{print $NF}')
echo "default: $DEFAULT"
[ "$DEFAULT" = "$SUBVOL_NAME/.snapshots/$NEW/snapshot" ] \
    || { echo "FAIL: the default subvolume is not snapshot $NEW"; exit 1; }
echo "OK: explicit --ambit classic warns and sets the default"
