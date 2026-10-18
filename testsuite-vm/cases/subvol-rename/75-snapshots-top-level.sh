# Split layout: /var and .snapshots are top-level subvolumes mounted via fstab,
# so nothing is nested in the root and the rollback moves nothing. The
# snapshots stay usable across the rollback and its reboot.
echo "=== .snapshots as a top-level subvolume, separate /var ==="
[ "$(findmnt -n -o FSTYPE /var)" = btrfs ] || { echo "SKIP: needs a separate /var subvolume"; exit 0; }
ensure_config

STATE=/snapshots-top-level.state   # in the root, written before the target snapshot
PHASE=0
[ -f "$STATE" ] && . "$STATE"

case "$PHASE" in
0)
    # replace the nested .snapshots by a top-level subvolume mounted via fstab
    for n in $(snapper --no-dbus -c root --csvout list --columns number | tail -n +3); do
        snapper --no-dbus -c root delete "$n"
    done
    btrfs subvolume delete /.snapshots
    mkdir /.snapshots
    T=$(toplevel_mount)
    btrfs subvolume create "$T/snapshots"
    toplevel_umount "$T"
    awk '$2=="/" { $2="/.snapshots"; sub(/subvol=[^,]*/, "subvol=snapshots", $4); print }' OFS="\t" \
        /etc/fstab >> /etc/fstab
    grep '/.snapshots' /etc/fstab
    printf 'PHASE=1\n' > "$STATE"
    engine_reboot
    ;;
1)
    findmnt -n /.snapshots || { echo "FAIL: setup: /.snapshots is not mounted"; exit 1; }
    printf 'PHASE=2\n' > "$STATE"
    PRE=$(snapper --no-dbus -c root create -d "top-level-snapshots-target" -p)
    echo "$PRE" > /var/tmp/top-level-target   # /var is not part of the rollback
    echo gone > /top-level-snapshots-marker
    snapper --no-dbus -c root rollback "$PRE"
    engine_reboot
    ;;
2)
    [ ! -e /top-level-snapshots-marker ] || { echo "FAIL: the rollback did not take effect"; exit 1; }
    findmnt -n /.snapshots || { echo "FAIL: /.snapshots is not mounted after the rollback"; exit 1; }
    PRE=$(cat /var/tmp/top-level-target)
    snapper --no-dbus -c root --csvout list --columns number | grep -qx "$PRE" \
        || { echo "FAIL: snapper no longer lists snapshot $PRE"; exit 1; }
    echo "OK: rollback with top-level .snapshots and /var"
    ;;
esac
