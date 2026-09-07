# A rollback must work with btrfs quota enabled (rollback creates snapshots with
# qgroup inheritance). Pre-reboot assertion only.
echo "=== rollback with btrfs quota enabled ($ROLLBACK_METHOD) ==="
ensure_config

echo "--- enable quota (snapper setup-quota) ---"
snapper --no-dbus -c root setup-quota
snapper --no-dbus -c root get-config | grep -i qgroup || true
btrfs qgroup show / 2>/dev/null | head || true

echo "--- rollback with quota enabled ---"
PRE=$(snapper --no-dbus -c root create -d "quota-rollback" -p)
OUT=$(snapper --no-dbus -c root rollback "$PRE" 2>&1)
echo "$OUT"
! echo "$OUT" | grep -qiE 'qgroup[^\n]*(fail|error)' || { echo "FAIL: qgroup error during rollback"; exit 1; }
snapper --no-dbus -c root list >/dev/null || { echo "FAIL: snapper unusable after quota rollback"; exit 1; }
echo "OK: rollback with quota enabled, no qgroup errors"
