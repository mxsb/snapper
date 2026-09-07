# A rollback must work with btrfs quota enabled (rollback creates snapshots with
# qgroup inheritance). Pre-reboot assertion only.
echo "=== rollback with btrfs quota enabled ($ROLLBACK_METHOD) ==="
ensure_config

echo "--- ensure quota is enabled (snapper setup-quota) ---"
# openSUSE ships snapper with btrfs quota already enabled, so setup-quota reports
# the qgroup is already set. That is exactly the precondition this case wants, so
# tolerate it and fail only on a different error.
if ! snapper --no-dbus -c root setup-quota 2>/tmp/quota.err; then
    if grep -qi 'already set' /tmp/quota.err; then
        echo "quota already enabled: $(cat /tmp/quota.err)"
    else
        echo "FAIL: setup-quota failed:"; cat /tmp/quota.err; exit 1
    fi
fi
snapper --no-dbus -c root get-config | grep -i qgroup || true
btrfs qgroup show / 2>/dev/null | head || true

echo "--- rollback with quota enabled ---"
PRE=$(snapper --no-dbus -c root create -d "quota-rollback" -p)
OUT=$(snapper --no-dbus -c root rollback "$PRE" 2>&1)
echo "$OUT"
! echo "$OUT" | grep -qiE 'qgroup[^\n]*(fail|error)' || { echo "FAIL: qgroup error during rollback"; exit 1; }
snapper --no-dbus -c root list >/dev/null || { echo "FAIL: snapper unusable after quota rollback"; exit 1; }
echo "OK: rollback with quota enabled, no qgroup errors"
