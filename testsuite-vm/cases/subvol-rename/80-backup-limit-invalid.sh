# An invalid ROLLBACK_BACKUP_LIMIT is a config error: the subvol-rename rollback
# that uses it is refused before anything is changed. Other commands do not use
# the value and must keep working (e.g. the snapshots of package managers).
echo "=== invalid ROLLBACK_BACKUP_LIMIT refuses the rollback ==="
ensure_config

CONF=/etc/snapper/configs/root
sed -i '/^ROLLBACK_BACKUP_LIMIT=/d' "$CONF"
echo 'ROLLBACK_BACKUP_LIMIT="ten"' >> "$CONF"

PRE=$(snapper --no-dbus -c root create -d "invalid-limit" -p) \
    || { echo "FAIL: snapper create broken by the invalid value"; exit 1; }
snapper --no-dbus -c root list >/dev/null \
    || { echo "FAIL: snapper list broken by the invalid value"; exit 1; }

BEFORE=$(snapper --no-dbus -c root --csvout list --columns number | tail -n +2 | sort -n | tr '\n' ' ')
if OUT=$(snapper --no-dbus -c root rollback "$PRE" 2>&1); then
    echo "$OUT"
    echo "FAIL: rollback succeeded with ROLLBACK_BACKUP_LIMIT=ten"; exit 1
fi
echo "$OUT"
echo "$OUT" | grep -q "is invalid" || { echo "FAIL: no config error reported"; exit 1; }

AFTER=$(snapper --no-dbus -c root --csvout list --columns number | tail -n +2 | sort -n | tr '\n' ' ')
[ "$BEFORE" = "$AFTER" ] || { echo "FAIL: snapshots changed: '$BEFORE' -> '$AFTER'"; exit 1; }

T=$(toplevel_mount)
LEFT=$(ls -d "$T/$SUBVOL_NAME".incoming "$T/$SUBVOL_NAME".rollback.* 2>/dev/null || true)
toplevel_umount "$T"
[ -z "$LEFT" ] || { echo "FAIL: refused rollback left subvolumes behind: $LEFT"; exit 1; }
echo "rollback refused, nothing changed, other commands unaffected"
