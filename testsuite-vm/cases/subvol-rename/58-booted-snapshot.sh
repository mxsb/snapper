# Rollback from a booted snapshot: boot a read-write snapshot once by its
# nested name, run "snapper rollback" without an argument there, boot normally:
# the root subvolume (from fstab) now has the content of that snapshot, and
# the old root is kept as a backup. A nested .snapshots is only a placeholder
# in the booted snapshot, so it is mounted there, as a user would have to.
echo "=== rollback from a booted snapshot ==="

STATE=/booted-snapshot.state   # in the root, and in the snapshot made after it
PHASE=0
[ -f "$STATE" ] && . "$STATE"
ENTRIES=$(boot_entries)

case "$PHASE" in
0)
    ensure_config
    ROOT=$SUBVOL_NAME
    printf 'PHASE=1\nROOT=%s\n' "$ROOT" > "$STATE"
    N=$(snapper --no-dbus -c root create --read-write -d "booted-snapshot-target" -p)
    # boot snapshot N once; the originals are restored before the next reboot
    for f in $ENTRIES; do
        [ -f "$f" ] || continue
        cp "$f" "$f.orig"
        sed -i -E "s#rootflags=subvol=/?$ROOT([[:space:]])#rootflags=subvol=$ROOT/.snapshots/$N/snapshot\1#g" "$f"
    done
    engine_reboot
    ;;
1)
    echo "booted: $(findmnt -n -o OPTIONS /)"
    findmnt -n -o OPTIONS / | grep -q "subvol=/$ROOT/.snapshots/[0-9]*/snapshot" \
        || { echo "FAIL: setup: did not boot the snapshot"; exit 1; }
    echo "/.snapshots in the booted snapshot: $(ls -A /.snapshots | wc -l) entries"
    snapper --no-dbus -c root list >/dev/null 2>&1 && echo "snapper works without a mount" \
        || echo "snapper does not work without a mount"
    if [ -z "$(ls -A /.snapshots)" ]; then
        dev=$(findmnt -n -o SOURCE / | sed 's/\[.*$//')
        mount -o "subvol=$ROOT/.snapshots" "$dev" /.snapshots
    fi

    printf 'PHASE=2\nROOT=%s\n' "$ROOT" > "$STATE"
    echo "only in the booted snapshot" > /booted-snapshot-file
    snapper --no-dbus -c root rollback

    for f in $ENTRIES; do [ -f "$f.orig" ] && mv "$f.orig" "$f"; done
    engine_reboot
    ;;
2)
    ensure_config
    echo "booted: $(findmnt -n -o OPTIONS /)"
    findmnt -n -o OPTIONS / | grep -q "subvol=/$ROOT\(,\|$\)" \
        || { echo "FAIL: did not boot the root subvolume $ROOT normally"; exit 1; }
    [ -f /booted-snapshot-file ] || { echo "FAIL: the root does not have the booted snapshot's content"; exit 1; }
    T=$(toplevel_mount)
    ls -d "$T/$ROOT".rollback.* >/dev/null 2>&1 || { toplevel_umount "$T"; echo "FAIL: the old root was not kept"; exit 1; }
    toplevel_umount "$T"
    snapper --no-dbus -c root list >/dev/null || { echo "FAIL: snapper does not work"; exit 1; }
    echo "OK: the booted snapshot became the root, the old root is kept"
    ;;
esac
