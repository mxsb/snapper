# Empty subvolumes nested in the root subvolume (Fedora's var/lib/portables and
# var/lib/machines) must not break their paths: a btrfs snapshot only holds a
# placeholder (inode 2) for them, which nothing can be created in. The rollback
# removes those placeholders from the new root, so systemd-tmpfiles recreates
# the subvolumes at boot.
echo "=== empty nested subvolumes across rollback ==="
ensure_config

STATE=/nested-empty.state   # in the root subvolume, written before the snapshot
PHASE=0
[ -f "$STATE" ] && . "$STATE"

case "$PHASE" in
0)
    btrfs subvolume list -o /
    # one of our own on every distro, plus the distro's empty nested ones
    btrfs subvolume create /nested-diag
    TMPFILES=""
    for p in /var/lib/portables /var/lib/machines; do
        if [ "$(stat -c %i "$p" 2>/dev/null)" = 256 ] && ! findmnt -n "$p" >/dev/null \
           && [ -z "$(ls -A "$p")" ]; then
            TMPFILES="$TMPFILES $p"
        fi
    done
    echo "nested subvolumes recreated by systemd-tmpfiles:${TMPFILES:- none}"

    printf 'PHASE=1\nTMPFILES="%s"\n' "$TMPFILES" > "$STATE"
    PRE=$(snapper --no-dbus -c root create -d "nested-empty" -p)
    echo "rollback-target" > /rollback-test-gone
    snapper --no-dbus -c root rollback "$PRE"
    engine_reboot
    ;;
1)
    if [ -e /rollback-test-gone ]; then
        echo "FAIL: rollback did not take effect"; exit 1
    fi

    BAD=""
    if [ "$(stat -c %i /nested-diag 2>/dev/null)" = 2 ]; then
        BAD="$BAD /nested-diag(placeholder)"
    fi
    for p in $TMPFILES; do
        echo "$p: inode $(stat -c %i "$p" 2>/dev/null || echo missing)"
        [ "$(stat -c %i "$p" 2>/dev/null)" = 256 ] || BAD="$BAD $p(not-a-subvolume)"
        (echo new > "$p/diag-new") 2>/dev/null || BAD="$BAD $p(not-writable)"
    done

    if [ -n "$BAD" ]; then
        echo "FAIL: nested subvolume paths broken by the rollback:$BAD"; exit 1
    fi
    ;;
esac
