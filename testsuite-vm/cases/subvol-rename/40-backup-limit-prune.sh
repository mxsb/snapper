# ROLLBACK_BACKUP_LIMIT prunes old rollback backups down to the limit -- tested
# the way it actually happens: across several real rollback+reboot cycles.
#
# Each rollback renames the *current* running root into a <subvol>.rollback.<N>
# backup (always the newest, highest btrfs id) and makes a fresh root the new
# default; the engine then reboots ONTO that new root. So by the time an old
# backup is pruned, we rebooted off it cycles ago and it is safe to delete -- it
# is never the live root. (A single-boot test that fakes "old" backups inverts
# the id order and makes prune delete the mounted root, wedging the system; that
# is a test artifact, not real behavior.)
#
# With LIMIT=2 and three rollback cycles, the third rollback's prune removes the
# oldest (cycle-1) backup, leaving exactly 2. Reaching the prune through the
# `snapper rollback` client path is what exercises config reading end to end.
echo "=== ROLLBACK_BACKUP_LIMIT prunes across real rollback+reboot cycles ==="
ensure_config

STATE=/var/lib/snapper-prune-phase   # survives each rollback (written before it)
CONF=/etc/snapper/configs/root
phase=$(cat "$STATE" 2>/dev/null || echo 0)
echo "phase=$phase (subvol=$SUBVOL_NAME)"

ensure_limit() {
    if grep -q '^ROLLBACK_BACKUP_LIMIT=' "$CONF"; then
        sed -i 's/^ROLLBACK_BACKUP_LIMIT=.*/ROLLBACK_BACKUP_LIMIT="2"/' "$CONF"
    else
        echo 'ROLLBACK_BACKUP_LIMIT="2"' >> "$CONF"
    fi
    grep '^ROLLBACK_BACKUP_LIMIT=' "$CONF"
}

count_backups() {
    local t c
    t=$(toplevel_mount)
    c=$(ls -d "$t/$SUBVOL_NAME".rollback.* 2>/dev/null | wc -l)
    toplevel_umount "$t"
    echo "$c"
}

# Persist the next phase BEFORE creating the target snapshot, so the snapshot
# (hence the new root we roll back to and reboot into) carries it.
rollback_cycle() {
    local next="$1" pre
    ensure_limit
    echo "$next" > "$STATE"
    pre=$(snapper --no-dbus -c root create -d "prune-cycle-$next" -p)
    echo "cycle $next: rolling back to snapshot $pre"
    snapper --no-dbus -c root rollback "$pre"
}

case "$phase" in
    0)
        rollback_cycle 1
        engine_reboot ;;
    1)
        echo "backups after cycle 1: $(count_backups)"      # 1, no prune yet
        rollback_cycle 2
        engine_reboot ;;
    2)
        echo "backups after cycle 2: $(count_backups)"      # 2, still <= limit
        rollback_cycle 3
        engine_reboot ;;
    3)
        AFTER=$(count_backups)
        echo "backups after cycle 3 (LIMIT=2): $AFTER"
        test "$AFTER" -eq 2 \
            || { echo "FAIL: expected 2 backups after prune, got $AFTER"; exit 1; }
        # Sanity: snapper is usable on the final rolled-back root.
        snapper --no-dbus -c root list >/dev/null \
            || { echo "FAIL: snapper unusable after prune cycles"; exit 1; }
        rm -f "$STATE"
        echo "OK: ROLLBACK_BACKUP_LIMIT pruned old backups down to 2 via the client path" ;;
    *)
        echo "FAIL: unexpected phase '$phase'"; exit 1 ;;
esac
