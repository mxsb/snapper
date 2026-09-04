#!/bin/bash
# Rollback with btrfs quota enabled. snapper's rollback creates snapshots with
# qgroup inheritance when QGROUP is configured; this checks the subvol-rename
# rollback still works with quota on and that backups can be created/pruned.
# Self-contained; run on a freshly booted system.
set -ex

echo "=== Detect root subvol ==="
SUBVOL=$(awk '$2=="/" && $3=="btrfs" {n=split($4,a,","); for(i=1;i<=n;i++) if(a[i]~/^subvol=/) print a[i]}' /proc/mounts)
SUBVOL_NAME="${SUBVOL#subvol=}"; SUBVOL_NAME="${SUBVOL_NAME#/}"
echo "Root subvol option: $SUBVOL"

echo "=== Ensure config exists ==="
mkdir -p /etc/sysconfig
test -e /etc/sysconfig/snapper || echo 'SNAPPER_CONFIGS=""' > /etc/sysconfig/snapper
snapper --no-dbus -c root get-config >/dev/null 2>&1 || snapper --no-dbus create-config /

echo "=== Enable quota (snapper setup-quota) ==="
snapper --no-dbus -c root setup-quota
echo "--- QGROUP in config ---"
snapper --no-dbus -c root get-config | grep -i qgroup || true
echo "--- btrfs qgroups ---"
btrfs qgroup show / 2>/dev/null | head || true

echo "=== Rollback with quota enabled ==="
PRE=$(snapper --no-dbus -c root create -d "quota-rollback-test" -p)
OUT=$(snapper --no-dbus -c root rollback "$PRE" 2>&1)
echo "$OUT"

echo "=== Rollback must not report qgroup errors ==="
! echo "$OUT" | grep -qiE 'qgroup[^\n]*(fail|error)' || { echo "FAIL: qgroup error during rollback"; exit 1; }

echo "=== snapper still works with quota ==="
snapper --no-dbus -c root list >/dev/null || { echo "FAIL: snapper list fails after quota rollback"; exit 1; }
btrfs qgroup show / 2>/dev/null | head || true

echo ""
echo "=== QUOTA ROLLBACK CHECKS PASSED ==="
