# Data in a subvolume nested inside the root subvolume must stay reachable, and
# the path usable, after a rollback (aschnell's /var/lib/portables report on PR
# #1184).
#
# A btrfs snapshot does not recurse into nested subvolumes: where one was, the
# snapshot only holds a placeholder (inode 2, BTRFS_EMPTY_SUBVOL_DIR_OBJECTID), an
# empty directory nothing can be created in (create -> EACCES, mkdir -> EPERM)
# until it is removed with rmdir.
#
# It tests a subvolume it creates itself (/nested-diag, every distro) plus the
# distro's own nested subvolumes (e.g. Fedora's var/lib/portables).
echo "=== nested subvolume data across rollback ($ROLLBACK_METHOD) ==="
ensure_config

STATE=/nested-diag.state   # in the root subvolume, written before the snapshot

describe() {   # describe <path>: one line on what is at <path> now
    local p="$1" ino
    ino=$(stat -c %i "$p" 2>/dev/null) || { echo "$p: missing"; return; }
    case "$ino" in
        256) echo "$p: subvolume (id $(btrfs inspect-internal rootid "$p"), $(ls -A "$p" | wc -l) entries)" ;;
        2)   echo "$p: placeholder of a subvolume not in this snapshot (inode 2)" ;;
        *)   echo "$p: $(stat -c %F "$p") ($(ls -A "$p" | wc -l) entries)" ;;
    esac
}

find_data() {   # find_data <path> <file>: where on the filesystem the file ended up
    local T
    T=$(toplevel_mount)
    find "$T" -name "$2" -path "*$1/$2" 2>/dev/null | sed "s|^$T|<toplevel>|"
    toplevel_umount "$T"
}

PHASE=0
[ -f "$STATE" ] && . "$STATE"

case "$PHASE" in
0)
    echo "--- inventory: subvolumes below the running root ---"
    btrfs subvolume list -o / || true
    findmnt -n -o SOURCE,OPTIONS /

    btrfs subvolume create /nested-diag
    PATHS="/nested-diag"
    for p in /var/lib/portables /var/lib/machines; do
        if [ "$(stat -c %i "$p" 2>/dev/null)" = 256 ] && ! findmnt -n "$p" >/dev/null; then
            PATHS="$PATHS $p"
            btrfs subvolume show "$p" | grep -E 'Creation time|Generation|Parent ID' || true
        fi
    done
    echo "testing nested subvolumes: $PATHS"

    for p in $PATHS; do
        describe "$p"
        echo data > "$p/diag-data"
    done

    printf 'PHASE=1\nPATHS="%s"\n' "$PATHS" > "$STATE"
    PRE=$(snapper --no-dbus -c root create -d "nested-diag" -p)
    snapper --no-dbus -c root rollback "$PRE"
    engine_reboot
    ;;
1)
    echo "--- after rollback + reboot ---"
    BAD=""
    for p in $PATHS; do
        describe "$p"
        if [ -f "$p/diag-data" ]; then
            echo "  $p/diag-data: present"
        else
            echo "  $p/diag-data: NOT at its path; found at: $(find_data "$p" diag-data | tr '\n' ' ')"
            BAD="$BAD $p(data)"
        fi
        if (echo new > "$p/diag-new") 2>/dev/null; then
            echo "  $p: writable"
        else
            echo "  $p: NOT writable"
            BAD="$BAD $p(write)"
        fi
    done

    if [ -n "$BAD" ]; then
        echo "FAIL: nested subvolume paths broken by the rollback:$BAD"
        exit 1
    fi
    ;;
esac
