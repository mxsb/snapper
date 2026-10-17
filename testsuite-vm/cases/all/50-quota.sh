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

# The root after the rollback is no snapshot snapper may clean up, so it must
# not be in the snapshot qgroup: SPACE_LIMIT would count the live root as
# snapshot space. Snapper only adds snapshots with a cleanup algorithm to it.
echo "--- new root must not be in the snapshot qgroup ---"
QGROUP=$(snapper --no-dbus -c root get-config | awk -F'│' '$1 ~ /^QGROUP/ {gsub(/ /,"",$2); print $2}')
[ -n "$QGROUP" ] || { echo "FAIL: QGROUP not set after setup-quota"; exit 1; }
T=$(toplevel_mount)
if [ "$ROLLBACK_METHOD" = subvol-rename ]; then
    NEW_ROOT_ID=$(btrfs inspect-internal rootid "$T/$SUBVOL_NAME")
else
    NEW_ROOT_ID=$(btrfs subvolume get-default "$T" | awk '{print $2}')
fi
PCOL=$(btrfs qgroup show -p --raw "$T" | head -1 | awk '{for(i=1;i<=NF;i++) if($i=="Parent") print i}')
PARENTS=$(btrfs qgroup show -p --raw "$T" | awk -v q="0/$NEW_ROOT_ID" -v c="$PCOL" '$1==q {print $c}')
# positive control: the rollback's backup snapshot has a cleanup algorithm, so
# it is in the qgroup, proving the membership check above can see one
BACKUP=$(echo "$OUT" | sed -n 's/.*read-only snapshot.*(Snapshot \([0-9]*\)\.).*/\1/p')
BACKUP_ID=$(btrfs inspect-internal rootid "/.snapshots/$BACKUP/snapshot")
BACKUP_PARENTS=$(btrfs qgroup show -p --raw "$T" | awk -v q="0/$BACKUP_ID" -v c="$PCOL" '$1==q {print $c}')
toplevel_umount "$T"
echo "QGROUP=$QGROUP new root 0/$NEW_ROOT_ID parents: ${PARENTS:--}; backup #$BACKUP 0/$BACKUP_ID parents: ${BACKUP_PARENTS:--}"
case ",$BACKUP_PARENTS," in
    *",$QGROUP,"*) ;;
    *) echo "FAIL: backup snapshot #$BACKUP not in $QGROUP, the qgroup check is broken"; exit 1 ;;
esac
case ",$PARENTS," in
    *",$QGROUP,"*) echo "FAIL: new root 0/$NEW_ROOT_ID is in the snapshot qgroup $QGROUP"; exit 1 ;;
esac
echo "OK: rollback with quota enabled, no qgroup errors"
