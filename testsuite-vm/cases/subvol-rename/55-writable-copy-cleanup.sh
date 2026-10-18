# The lifecycle of the writable copies, as in classic: after three rollbacks
# only the one the root was copied from has no cleanup algorithm, the earlier
# ones get "number" at the next rollback, so they do not pile up.
echo "=== cleanup of the writable copies over three rollbacks ==="
ensure_config

STATE=/writable-copy-cleanup.state   # in the root, written before each target snapshot
PHASE=0
[ -f "$STATE" ] && . "$STATE"

if [ "$PHASE" -lt 3 ]; then
    printf 'PHASE=%s\n' $((PHASE + 1)) > "$STATE"
    PRE=$(snapper --no-dbus -c root create -d "copy-cleanup-target-$PHASE" -p)
    snapper --no-dbus -c root rollback "$PRE"
    engine_reboot
fi

LIST=$(snapper --no-dbus -c root --csvout list --columns number,cleanup,description)
echo "$LIST"
COPIES=$(echo "$LIST" | awk -F, '$3 ~ /^writable copy/')
[ "$(echo "$COPIES" | wc -l)" = 3 ] || { echo "FAIL: expected 3 writable copies"; exit 1; }
LATEST=$(echo "$COPIES" | tail -1)
[ -z "$(echo "$LATEST" | cut -d, -f2)" ] \
    || { echo "FAIL: the latest writable copy has a cleanup algorithm: $LATEST"; exit 1; }
echo "$COPIES" | head -2 | awk -F, '$2 != "number" { bad = 1 } END { exit bad }' \
    || { echo "FAIL: an earlier writable copy has no number cleanup"; exit 1; }
echo "OK: only the latest writable copy is kept without cleanup"
