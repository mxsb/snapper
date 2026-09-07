# On a set-default (openSUSE-style) system, a read-only default snapshot makes the
# ambit transactional: the rollback just sets the default subvolume to the target
# without creating snapshots. (No reboot: booting a read-only root is distro
# tooling, not snapper's contract.)
echo "=== transactional ambit ==="
ensure_config

DEFAULT_PATH=$(btrfs subvolume get-default / | sed 's/.*path //')
DEFN=$(echo "$DEFAULT_PATH" | sed -n 's|.*\.snapshots/\([0-9]*\)/snapshot$|\1|p')
if [ -z "$DEFN" ]; then echo "SKIP: default subvolume is not a snapper snapshot"; exit 0; fi
echo "default snapshot: $DEFN"

echo "--- make the default snapshot read-only (as on a transactional system) ---"
btrfs property set "/.snapshots/$DEFN/snapshot" ro true

TARGET=$(snapper --no-dbus -c root create -d "transactional-target" -p)
OUT=$(snapper --no-dbus -c root rollback "$TARGET" 2>&1)
echo "$OUT"
if ! echo "$OUT" | grep -q "Ambit is transactional."; then
    echo "FAIL: expected transactional ambit"
    btrfs property set "/.snapshots/$DEFN/snapshot" ro false; exit 1
fi
btrfs subvolume get-default / | grep -q "\.snapshots/$TARGET/snapshot" \
    || { echo "FAIL: default subvolume not set to the target"; exit 1; }

echo "--- restore previous default ---"
btrfs subvolume set-default "/.snapshots/$DEFN/snapshot"
btrfs property set "/.snapshots/$DEFN/snapshot" ro false
echo "OK: transactional ambit detected and default set to the target"
