#!/bin/bash
# Second rollback cycle, run after the first rollback has been verified by a
# reboot. On a top-level named subvolume a colliding <subvol>.rollback.<N> is
# created up front, so the rollback must fall back to the subvolume-id-based
# rescue name. On set-default systems this is a plain repeated rollback.
set -ex

echo "=== Detect root subvol ==="
SUBVOL=$(awk '$2 == "/" && $3 == "btrfs" {n=split($4,a,","); for(i=1;i<=n;i++) if (a[i] ~ /^subvol=/) print a[i]}' /proc/mounts)
SUBVOL_NAME="${SUBVOL#subvol=}"
SUBVOL_NAME="${SUBVOL_NAME#/}"
echo "Root subvol option: $SUBVOL"

echo "=== Create pre-rollback snapshot ==="
PRE=$(snapper --no-dbus -c root create -d "second-rollback-test" -p)
echo "Snapshot number: $PRE"

echo "=== Create post-snapshot marker ==="
echo "this-should-disappear-after-second-rollback" > /test-marker2-$$

if [ -n "$SUBVOL_NAME" ] && [[ "$SUBVOL_NAME" != */* ]]; then
    # The rollback preserves the old root as <subvol>.rollback.<N> where N is
    # the number of the read-write copy it creates: the first rollback snapshot
    # gets PRE+1, the copy PRE+2.
    NEXT2=$((PRE + 2))

    DEV=$(findmnt -n -o SOURCE / | sed 's/\[.*$//')
    TOPMNT=$(mktemp -d)
    mount -o subvolid=5 "$DEV" "$TOPMNT"

    echo "=== Pre-create colliding $SUBVOL_NAME.rollback.$NEXT2 to force the svid fallback ==="
    btrfs subvolume create "$TOPMNT/$SUBVOL_NAME.rollback.$NEXT2"

    echo "=== Second rollback (expecting svid fallback) ==="
    snapper --no-dbus -c root rollback "$PRE"

    echo "=== Verify svid fallback subvolume exists ==="
    ls -la "$TOPMNT"/
    ls -d "$TOPMNT/$SUBVOL_NAME".rollback.svid.*

    umount "$TOPMNT"
    rmdir "$TOPMNT"
else
    echo "=== Second rollback (set-default) ==="
    snapper --no-dbus -c root rollback "$PRE"
fi

sync

echo ""
echo "=== SECOND-CYCLE PRE-REBOOT CHECKS PASSED ==="
echo "MARKER_FILE=/test-marker2-$$"
