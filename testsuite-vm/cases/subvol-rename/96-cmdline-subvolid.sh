# Kernel command line with subvolid= next to subvol=: after a rename the id
# names the old root and the kernel refuses the mismatch, so the system would
# not boot. The rollback must be refused before anything changes.
echo "=== subvolid= next to subvol= on the kernel command line ==="
ensure_config

STATE=/cmdline-subvolid.state   # in the root subvolume
PHASE=0
[ -f "$STATE" ] && . "$STATE"

case "$PHASE" in
0)
    ROOT_ID=$(btrfs inspect-internal rootid /)
    # append subvolid=<id> to rootflags=subvol=<name> in every boot entry
    for f in $(boot_entries); do
        [ -f "$f" ] || continue
        sed -i -E "s/(rootflags=subvol=[^[:space:],]+)/\1,subvolid=$ROOT_ID/g" "$f"
    done
    printf 'PHASE=1\nROOT_ID=%s\n' "$ROOT_ID" > "$STATE"
    engine_reboot
    ;;
1)
    echo "cmdline: $(cat /proc/cmdline)"
    grep -q "subvolid=$ROOT_ID" /proc/cmdline || { echo "FAIL: setup: subvolid= not on the command line"; exit 1; }

    PRE=$(snapper --no-dbus -c root create -d "cmdline-subvolid-target" -p)
    BEFORE=$(snapper --no-dbus -c root --csvout list --columns number | tail -n +2 | wc -l)
    OUT=$(snapper --no-dbus -c root rollback "$PRE" 2>&1) && rc=0 || rc=$?
    echo "$OUT"
    [ "$rc" -ne 0 ] || { echo "FAIL: the rollback was not refused"; exit 1; }
    echo "$OUT" | grep -q "subvolid=" || { echo "FAIL: the refusal does not name subvolid="; exit 1; }
    AFTER=$(snapper --no-dbus -c root --csvout list --columns number | tail -n +2 | wc -l)
    [ "$BEFORE" = "$AFTER" ] || { echo "FAIL: the refused rollback created snapshots"; exit 1; }
    T=$(toplevel_mount)
    [ "$(btrfs inspect-internal rootid "$T/$SUBVOL_NAME")" = "$ROOT_ID" ] \
        || { toplevel_umount "$T"; echo "FAIL: the root subvolume was replaced"; exit 1; }
    toplevel_umount "$T"
    echo "refused, nothing changed"
    ;;
esac
