# Prelude prepended to every rollback test case. Provides shared helpers and the
# common `set` flags. $ROLLBACK_METHOD is passed in by the engine.
set -euo pipefail

ROLLBACK_METHOD="${ROLLBACK_METHOD:-}"

# Named top-level subvolume of the root mount ("" when mounted by default id).
_detect_subvol() {
    awk '$2=="/" && $3=="btrfs"{
        n = split($4, a, ",")
        for (i = 1; i <= n; i++) if (a[i] ~ /^subvol=/) { sub(/^subvol=\/?/, "", a[i]); print a[i] }
    }' /proc/mounts
}
SUBVOL_NAME="$(_detect_subvol)"

# Skip this case (the engine reports it) unless a capability is available.
requires() {
    case "$1" in
        selinux)
            if ! command -v getenforce >/dev/null 2>&1 \
               || [ "$(getenforce 2>/dev/null)" = "Disabled" ] \
               || [ ! -e /sys/fs/selinux/enforce ]; then
                echo "SKIP: needs selinux (not available here)"; exit 0
            fi ;;
        quota) : ;;   # btrfs quota is always available
        *) echo "SKIP: unknown requirement '$1'"; exit 0 ;;
    esac
}

ensure_config() {
    mkdir -p /etc/sysconfig
    [ -e /etc/sysconfig/snapper ] || echo 'SNAPPER_CONFIGS=""' > /etc/sysconfig/snapper
    snapper --no-dbus -c root get-config >/dev/null 2>&1 || snapper --no-dbus create-config /
}

# Mount the btrfs top-level (subvolid=5) where the named root subvolumes live;
# echoes the mount point. Pair with toplevel_umount.
toplevel_mount() {
    local dev m
    dev=$(findmnt -n -o SOURCE / | sed 's/\[.*$//')
    m=$(mktemp -d)
    mount -o subvolid=5 "$dev" "$m"
    echo "$m"
}
toplevel_umount() { umount "$1"; rmdir "$1"; }

# Marker that must disappear after a correct rollback+reboot. Create it AFTER the
# pre-rollback snapshot; emit_marker tells the engine to verify it post-reboot.
MARKER="/rollback-test-marker-$$"
emit_marker() {
    echo "this-file-must-disappear-after-rollback" > "$MARKER"
    echo "MARKER_FILE=$MARKER"
}

# Like emit_marker, but the engine asserts the file STILL EXISTS after the reboot
# (for rollbacks that preserve data, e.g. no-argument rollback to the current
# state, and to prove the system boots on the new default).
emit_persist_marker() {
    echo "this-file-must-survive-the-rollback" > "$MARKER"
    echo "PERSIST_MARKER=$MARKER"
}

# Ask the engine to reboot the VM and re-run this case from the top. For
# multi-cycle scenarios (e.g. accumulating real rollback backups across several
# rollback+reboot cycles). The case must persist its own phase across the reboot
# in a file written BEFORE the rollback, so the rollback snapshot captures it.
engine_reboot() {
    echo "ENGINE_REBOOT"
    exit 0
}

# Trace the case body in the engine's captured output.
set -x
