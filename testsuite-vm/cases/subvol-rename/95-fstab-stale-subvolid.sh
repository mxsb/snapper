# fstab mounting / with subvol=<name> and subvolid=<id> (as genfstab writes it):
# after the rename the id names the backup. The kernel command line decides at
# boot, so the system must boot the new root normally, and / must still remount
# (systemd-remount-fs at boot, and by hand).
echo "=== rollback with subvolid= next to subvol= in fstab ==="
ensure_config

STATE=/stale-subvolid.state   # in the root subvolume, written before the snapshot
PHASE=0
[ -f "$STATE" ] && . "$STATE"

case "$PHASE" in
0)
    if ! awk '!/^[[:space:]]*#/ && $2=="/" {print $4}' /etc/fstab | grep -q 'subvolid='; then
        id=$(btrfs inspect-internal rootid /)
        sed -i -E "/^[^#][^[:space:]]*[[:space:]]+\/[[:space:]]+btrfs/ s/subvol=([^,[:space:]]+)/subvol=\1,subvolid=$id/" /etc/fstab
    fi
    echo "fstab /: $(awk '!/^[[:space:]]*#/ && $2=="/" {print $4}' /etc/fstab)"
    OLD_ID=$(btrfs inspect-internal rootid /)

    printf 'PHASE=1\nOLD_ID=%s\n' "$OLD_ID" > "$STATE"
    PRE=$(snapper --no-dbus -c root create -d "stale-subvolid-target" -p)
    echo gone > /stale-subvolid-marker
    OUT=$(snapper --no-dbus -c root rollback "$PRE" 2>&1)
    echo "$OUT"
    echo "$OUT" | grep -q "subvolid=" || { echo "FAIL: no warning about the stale subvolid="; exit 1; }
    engine_reboot
    ;;
1)
    echo "booted: $(btrfs inspect-internal rootid /) $(findmnt -n -o OPTIONS /)"
    [ "$(btrfs inspect-internal rootid /)" != "$OLD_ID" ] || { echo "FAIL: booted the old root"; exit 1; }
    [ ! -e /stale-subvolid-marker ] || { echo "FAIL: rollback did not take effect"; exit 1; }

    STATUS=$(systemctl is-system-running --wait || true)
    echo "system: $STATUS"; systemctl --failed --no-legend
    systemctl is-failed -q systemd-remount-fs.service && { echo "FAIL: systemd-remount-fs failed"; exit 1; }
    [ "$STATUS" = running ] || { echo "FAIL: system is $STATUS"; exit 1; }

    mount -o remount / || { echo "FAIL: remounting / with the fstab options fails"; exit 1; }
    echo "boots and remounts with the stale subvolid="
    ;;
esac
