#!/bin/bash
# Third rollback cycle, run after the second has been verified by a reboot.
# Verifies the ROLLBACK_BACKUP_LIMIT retention: on a named-subvolume layout the
# previous rollbacks left several <subvol>.rollback.* backups; with the limit
# set, this rollback must prune them down to the configured count (keeping the
# newest, including the one it just created). On set-default systems the limit
# is inert and this is simply a third rollback.
set -ex

echo "=== Detect root subvol ==="
SUBVOL=$(awk '$2 == "/" && $3 == "btrfs" {n=split($4,a,","); for(i=1;i<=n;i++) if (a[i] ~ /^subvol=/) print a[i]}' /proc/mounts)
SUBVOL_NAME="${SUBVOL#subvol=}"
SUBVOL_NAME="${SUBVOL_NAME#/}"
echo "Root subvol option: $SUBVOL"

CONF=/etc/snapper/configs/root
echo "=== Set ROLLBACK_BACKUP_LIMIT=2 in $CONF ==="
if grep -q '^ROLLBACK_BACKUP_LIMIT=' "$CONF"; then
    sed -i 's/^ROLLBACK_BACKUP_LIMIT=.*/ROLLBACK_BACKUP_LIMIT="2"/' "$CONF"
else
    echo 'ROLLBACK_BACKUP_LIMIT="2"' >> "$CONF"
fi
grep '^ROLLBACK_BACKUP_LIMIT=' "$CONF"

echo "=== Create pre-rollback snapshot ==="
PRE=$(snapper --no-dbus -c root create -d "third-rollback-test" -p)
echo "Snapshot number: $PRE"

echo "=== Create post-snapshot marker ==="
# Must be created AFTER the PRE snapshot so it is not part of the rollback
# target and therefore disappears once the rollback takes effect.
echo "this-should-disappear-after-third-rollback" > /test-marker3-$$

if [ -n "$SUBVOL_NAME" ] && [[ "$SUBVOL_NAME" != */* ]]; then
    DEV=$(findmnt -n -o SOURCE / | sed 's/\[.*$//')
    TOPMNT=$(mktemp -d)
    mount -o subvolid=5 "$DEV" "$TOPMNT"

    echo "=== Backups before third rollback ==="
    ls -d "$TOPMNT/$SUBVOL_NAME".rollback.* 2>/dev/null || true
    BEFORE=$(ls -d "$TOPMNT/$SUBVOL_NAME".rollback.* 2>/dev/null | wc -l)
    echo "backup count before: $BEFORE"
    # There must be more than the limit already, otherwise the test proves nothing.
    test "$BEFORE" -gt 2 || { echo "FAIL: expected >2 pre-existing backups, got $BEFORE"; exit 1; }
    test -d "$TOPMNT/$SUBVOL_NAME.rollback.5" && HAD_OLDEST=yes || HAD_OLDEST=no

    echo "=== Third rollback (ROLLBACK_BACKUP_LIMIT=2) ==="
    snapper --no-dbus -c root rollback "$PRE"

    echo "=== Backups after third rollback ==="
    ls -d "$TOPMNT/$SUBVOL_NAME".rollback.* 2>/dev/null || true
    AFTER=$(ls -d "$TOPMNT/$SUBVOL_NAME".rollback.* 2>/dev/null | wc -l)
    echo "backup count after: $AFTER"

    echo "=== Assert exactly 2 backups remain ==="
    test "$AFTER" -eq 2 || { echo "FAIL: expected 2 backups after ROLLBACK_BACKUP_LIMIT=2, got $AFTER"; exit 1; }

    if [ "$HAD_OLDEST" = yes ]; then
	echo "=== Assert the oldest (cycle-1) backup was pruned ==="
	test ! -d "$TOPMNT/$SUBVOL_NAME.rollback.5" || \
	    { echo "FAIL: oldest backup $SUBVOL_NAME.rollback.5 was not pruned"; exit 1; }
    fi

    umount "$TOPMNT"
    rmdir "$TOPMNT"
else
    echo "=== Third rollback (set-default; ROLLBACK_BACKUP_LIMIT inert) ==="
    snapper --no-dbus -c root rollback "$PRE"
fi

sync

echo ""
echo "=== THIRD-CYCLE (ROLLBACK_BACKUP_LIMIT) PRE-REBOOT CHECKS PASSED ==="
echo "MARKER_FILE=/test-marker3-$$"
