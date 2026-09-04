#!/bin/bash
# Rollback under SELinux enforcing. The subvol-rename rollback re-mounts the
# .snapshots subvolume on the running root (to keep snapper working before the
# reboot); verify that this works and stays accessible when SELinux enforces.
# Self-contained; run on a freshly booted named-subvolume system.
set -ex

if ! command -v getenforce >/dev/null 2>&1 || [ "$(getenforce 2>/dev/null)" = "Disabled" ]; then
    echo "=== SELinux not available - skipping ==="
    exit 0
fi

SUBVOL=$(awk '$2=="/" && $3=="btrfs" {n=split($4,a,","); for(i=1;i<=n;i++) if(a[i]~/^subvol=/) print a[i]}' /proc/mounts)
SUBVOL_NAME="${SUBVOL#subvol=}"; SUBVOL_NAME="${SUBVOL_NAME#/}"
if [ -z "$SUBVOL_NAME" ] || [[ "$SUBVOL_NAME" == */* ]]; then
    echo "=== Not a top-level named subvolume - re-mount check not applicable ==="
    exit 0
fi

echo "=== Ensure config exists ==="
mkdir -p /etc/sysconfig
test -e /etc/sysconfig/snapper || echo 'SNAPPER_CONFIGS=""' > /etc/sysconfig/snapper
snapper --no-dbus -c root get-config >/dev/null 2>&1 || snapper --no-dbus create-config /

echo "=== Switch SELinux to enforcing ==="
setenforce 1
test "$(getenforce)" = "Enforcing" || { echo "FAIL: could not set enforcing"; exit 1; }

echo "=== /.snapshots label before rollback ==="
ls -Zd /.snapshots

echo "=== Rollback under enforcing ==="
PRE=$(snapper --no-dbus -c root create -d "selinux-rollback-test" -p)
snapper --no-dbus -c root rollback "$PRE"

echo "=== /.snapshots after rollback (re-mounted) ==="
findmnt /.snapshots
ls -Zd /.snapshots

echo "=== snapper must work under enforcing after the re-mount ==="
snapper --no-dbus -c root list >/dev/null || \
    { echo "FAIL: snapper list fails under SELinux enforcing after rollback"; exit 1; }

echo "=== snapper create/delete must work under enforcing ==="
NEW=$(snapper --no-dbus -c root create -d "selinux-write-test" -p)
test -e "/.snapshots/$NEW/info.xml" || { echo "FAIL: created snapshot not visible under enforcing"; exit 1; }
snapper --no-dbus -c root delete "$NEW"

echo "=== report any snapshot-related AVC denials (informational) ==="
if command -v ausearch >/dev/null 2>&1; then
    ausearch -m avc -ts recent 2>/dev/null | grep -i snapshot && echo "WARN: AVC denials referencing snapshot (see above)" || echo "no snapshot AVC denials"
fi

echo ""
echo "=== SELINUX ENFORCING ROLLBACK CHECKS PASSED ==="
