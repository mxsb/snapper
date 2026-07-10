#!/bin/bash
# Regression test for the transactional ambit, run after the second rollback
# cycle on a set-default system: marking the default snapshot read-only is
# what the ambit auto-detection keys on, so a rollback must then detect the
# transactional ambit and set the default subvolume to the existing target
# without creating any snapshots. No reboot: booting a read-only root is
# distro tooling (transactional-update), not snapper's contract.
set -ex

echo "=== Detect root subvol ==="
SUBVOL=$(awk '$2 == "/" && $3 == "btrfs" {n=split($4,a,","); for(i=1;i<=n;i++) if (a[i] ~ /^subvol=/) print a[i]}' /proc/mounts)
SUBVOL_NAME="${SUBVOL#subvol=}"
SUBVOL_NAME="${SUBVOL_NAME#/}"

if [ -n "$SUBVOL_NAME" ] && [[ "$SUBVOL_NAME" != */* ]]; then
    echo "=== Top-level named subvolume - transactional check not applicable ==="
    exit 0
fi

echo "=== Determine default snapshot ==="
DEFAULT_PATH=$(btrfs subvolume get-default / | sed 's/.*path //')
DEFN=$(echo "$DEFAULT_PATH" | sed -n 's|.*\.snapshots/\([0-9]*\)/snapshot$|\1|p')
if [ -z "$DEFN" ]; then
    echo "=== Default subvolume is not a snapper snapshot - transactional check not applicable ==="
    exit 0
fi
echo "Default snapshot: $DEFN"

echo "=== Make default snapshot read-only (as on a transactional system) ==="
btrfs property set "/.snapshots/$DEFN/snapshot" ro true

echo "=== Create rollback target ==="
TARGET=$(snapper --no-dbus -c root create -d "transactional-target" -p)
echo "Target snapshot: $TARGET"

echo "=== Rollback must detect the transactional ambit ==="
OUT=$(snapper --no-dbus -c root rollback "$TARGET" 2>&1)
echo "$OUT"
echo "$OUT" | grep -q "Ambit is transactional."

echo "=== Verify default subvolume points at the target ==="
btrfs subvolume get-default / | grep -q "\.snapshots/$TARGET/snapshot"

echo "=== Rollback to the default snapshot itself must be rejected ==="
if OUT=$(snapper --no-dbus -c root rollback "$TARGET" 2>&1); then
    echo "FAIL: rollback to the active default snapshot did not fail"
    exit 1
fi
echo "$OUT"
echo "$OUT" | grep -q "already default"

echo "=== Restore previous default ==="
btrfs subvolume set-default "/.snapshots/$DEFN/snapshot"
btrfs property set "/.snapshots/$DEFN/snapshot" ro false

echo ""
echo "=== TRANSACTIONAL CHECKS PASSED ==="
