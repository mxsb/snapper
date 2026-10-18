# snapper in a chroot (e.g. from a rescue system) rolls back the system of the
# chroot: /proc/cmdline belongs to the running kernel, not to that system, so
# its root subvolume must come from the chroot's fstab, as with --root. The
# chroot is a copy of the running root as a second system root2 in the same
# filesystem, the kernel command line names the running root.
echo "=== rollback in a chroot ==="
ensure_config

T=$(toplevel_mount)
btrfs subvolume snapshot "$T/$SUBVOL_NAME" "$T/root2"
sed -i -E "/^[^#][^[:space:]]*[[:space:]]+\/[[:space:]]+btrfs/ s/subvol=\/?$SUBVOL_NAME([,[:space:]])/subvol=root2\1/" "$T/root2/etc/fstab"
rmdir "$T/root2/.snapshots"                        # the placeholder of the nested .snapshots
btrfs subvolume create "$T/root2/.snapshots"
C=/mnt/chroot
mkdir -p "$C"
mount -o subvol=root2 "$(findmnt -n -o SOURCE / | sed 's/\[.*$//')" "$C"
for d in proc sys dev run; do mount --rbind /$d "$C/$d"; done
awk '$2=="/"' "$C/etc/fstab"

PRE=$(chroot "$C" snapper --no-dbus -c root create -d "chroot-target" -p)
OUT=$(chroot "$C" snapper --no-dbus -c root rollback "$PRE" 2>&1) && rc=0 || rc=$?
echo "$OUT"
umount -R "$C" || umount -R -l "$C"

fail=""
[ "$rc" -eq 0 ] || fail="the rollback in the chroot failed"
[ -n "$fail" ] || ls -d "$T"/root2.rollback.* >/dev/null 2>&1 || fail="root2 was not replaced"
[ -n "$fail" ] || ! ls -d "$T/$SUBVOL_NAME".rollback.* >/dev/null 2>&1 || fail="the running root was replaced"
toplevel_umount "$T"
[ -z "$fail" ] || { echo "FAIL: $fail"; exit 1; }
echo "OK: the chroot's root subvolume root2 was replaced"
