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
SUBVOL=$(awk '/ \/ /{for(i=1;i<=NF;i++) if($i ~ /subvol=/) print $i}' /proc/mounts)
echo "Root subvol option: $SUBVOL"

echo "=== Create pre-rollback snapshot ==="
PRE=$(snapper --no-dbus -c root create -d "pre-rollback-test" -p)
echo "Snapshot number: $PRE"

echo "=== Create post-snapshot marker ==="
echo "this-should-disappear-after-rollback" > /test-marker-$$

echo "=== Rollback ==="
snapper --no-dbus -c root rollback "$PRE"

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
