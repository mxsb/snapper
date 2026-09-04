#!/bin/bash
set -ex

echo "=== Ensure snapper sysconfig exists ==="
mkdir -p /etc/sysconfig
test -e /etc/sysconfig/snapper || echo 'SNAPPER_CONFIGS=""' > /etc/sysconfig/snapper

echo "=== Ensure snapper config exists ==="
snapper --no-dbus -c root get-config &>/dev/null || snapper --no-dbus create-config /

echo "=== Root mount ==="
grep ' / ' /proc/mounts

echo "=== Snapper config ==="
snapper --no-dbus -c root get-config | grep -iE 'SUBVOLUME|ROLLBACK' || true

echo "=== Verify detection ==="
SUBVOL=$(awk '$2 == "/" && $3 == "btrfs" {n=split($4,a,","); for(i=1;i<=n;i++) if (a[i] ~ /^subvol=/) print a[i]}' /proc/mounts)
echo "Root subvol option: $SUBVOL"

echo "=== Create pre-rollback snapshot ==="
PRE=$(snapper --no-dbus -c root create -d "pre-rollback-test" -p)
echo "Snapshot number: $PRE"

echo "=== Create post-snapshot marker ==="
echo "this-should-disappear-after-rollback" > /test-marker-$$

# Top-level named subvol mount (e.g. subvol=@root) - not "/", no nested path
SUBVOL_NAME="${SUBVOL#subvol=}"
SUBVOL_NAME="${SUBVOL_NAME#/}"
if [ -n "$SUBVOL_NAME" ] && [[ "$SUBVOL_NAME" != */* ]]; then
    echo "=== Verify warning for explicit --ambit classic on named subvolume '$SUBVOL_NAME' ==="
    OUT=$(snapper --no-dbus --ambit classic -c root rollback -d "ambit-classic-warning-test" "$PRE" 2>&1)
    echo "$OUT"
    echo "$OUT" | grep -q "will not take effect"
else
    echo "=== No top-level named subvolume - skipping --ambit classic warning check ==="
fi

echo "=== Rollback ==="
OUT=$(snapper --no-dbus -c root rollback "$PRE" 2>&1)
echo "$OUT"

echo "=== Verify no spurious warning from the default rollback ==="
! echo "$OUT" | grep -q "will not take effect"

echo "=== Verify snapper still works after rollback, before reboot ==="
# Regression test for the report that on a subvol-rename rollback /.snapshots
# disappears until the next reboot, leaving snapper unusable on the running
# system. The rollback moves the nested .snapshots subvolume into the new root;
# it must keep /.snapshots working on the still-running old root as well.
echo "--- findmnt /.snapshots ---"; findmnt /.snapshots || echo "(/.snapshots is not a separate mount)"
echo "--- /.snapshots contents ---"; ls -la /.snapshots 2>&1 || true
echo "--- snapper list (must succeed) ---"
snapper --no-dbus -c root list
ls /.snapshots/*/info.xml >/dev/null 2>&1 || \
    { echo "FAIL: no snapshots visible under /.snapshots after rollback (before reboot)"; exit 1; }
echo "Snapper is still functional before reboot."

echo "=== Verify snapper can create and delete snapshots before reboot ==="
# The re-mounted .snapshots must be writable, not just readable: create then
# delete a snapshot on the running (old) root before the reboot.
NEWSNAP=$(snapper --no-dbus -c root create -d "post-rollback-write-test" -p)
test -e "/.snapshots/$NEWSNAP/info.xml" || \
    { echo "FAIL: snapshot $NEWSNAP created after rollback is not visible under /.snapshots"; exit 1; }
snapper --no-dbus -c root delete "$NEWSNAP"
! test -e "/.snapshots/$NEWSNAP/info.xml" || \
    { echo "FAIL: snapshot $NEWSNAP still present after delete"; exit 1; }
echo "Snapper create/delete works on the re-mounted .snapshots before reboot."

echo "=== Verify rollback artifacts ==="
DEV=$(findmnt -n -o SOURCE / | sed 's/\[.*$//')
TOPMNT=$(mktemp -d)
mount -o subvolid=5 "$DEV" "$TOPMNT"

echo "Top-level subvolumes after rollback:"
ls -la "$TOPMNT"/ | grep -E '@|root'

umount "$TOPMNT"
rmdir "$TOPMNT"

sync

echo ""
echo "=== PRE-REBOOT CHECKS PASSED ==="
echo "MARKER_FILE=/test-marker-$$"
