# Kernel command line without rootflags=subvol=, fstab still naming the root
# subvolume, and the btrfs default subvolume set to it: the kernel mounts the
# default subvolume, so the rollback must change the default (set-default), and
# renaming the subvolume would not take effect on the next boot.
echo "=== kernel command line without subvol=, root booted by the default id ==="
ensure_config

STATE=/cmdline-without-subvol.state   # in the root subvolume, written before the snapshot
PHASE=0
[ -f "$STATE" ] && . "$STATE"

case "$PHASE" in
0)
    ROOT_ID=$(btrfs inspect-internal rootid /)
    # drop rootflags=subvol=... from every boot entry (other rootflags stay)
    for f in /boot/grub/grub.cfg /boot/grub2/grub.cfg /boot/loader/entries/*.conf; do
        [ -f "$f" ] || continue
        sed -i -E 's/[[:space:]]rootflags=subvol=[^[:space:]]*//g' "$f"
        grep -n 'linux\|options' "$f" | grep -v '^\s*#' | head -3
    done
    btrfs subvolume set-default "$ROOT_ID" /
    printf 'PHASE=1\nROOT_ID=%s\n' "$ROOT_ID" > "$STATE"
    engine_reboot
    ;;
1)
    echo "cmdline: $(cat /proc/cmdline)"
    grep -q 'subvol=' /proc/cmdline && { echo "FAIL: setup: subvol= still on the command line"; exit 1; }
    [ "$(btrfs inspect-internal rootid /)" = "$ROOT_ID" ] \
        || { echo "FAIL: setup: did not boot the root by the default id"; exit 1; }

    printf 'PHASE=2\nROOT_ID=%s\n' "$ROOT_ID" > "$STATE"
    PRE=$(snapper --no-dbus -c root create -d "cmdline-without-subvol-target" -p)
    emit_marker          # created AFTER $PRE, so the rollback removes it

    # auto must not rename: the default subvolume is no snapper snapshot here,
    # so the ambit cannot be detected and nothing may change
    OUT=$(snapper --no-dbus -c root rollback "$PRE" 2>&1) && rc=0 || rc=$?
    echo "$OUT"
    echo "$OUT" | grep -q "subvol-rename" && { echo "FAIL: auto chose subvol-rename"; exit 1; }
    [ "$rc" -ne 0 ] || { echo "FAIL: expected auto to stop without a detectable ambit"; exit 1; }
    [ "$(btrfs subvolume get-default / | awk '{print $2}')" = "$ROOT_ID" ] \
        || { echo "FAIL: the refused rollback changed the default subvolume"; exit 1; }

    # set-default is the method that changes what boots here
    snapper --no-dbus --ambit classic -c root rollback "$PRE"
    echo "default now: $(btrfs subvolume get-default /)"
    ;;
esac
