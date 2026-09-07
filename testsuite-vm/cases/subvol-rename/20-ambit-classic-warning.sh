# An explicit `--ambit classic` on a top-level named-subvolume root sets the
# default subvolume, which has no effect on the next boot -- snapper must warn.
echo "=== --ambit classic warning on named subvolume '$SUBVOL_NAME' ==="
ensure_config

PRE=$(snapper --no-dbus -c root create -d "warn-target" -p)
OUT=$(snapper --no-dbus --ambit classic -c root rollback -d "ambit-classic-warning" "$PRE" 2>&1)
echo "$OUT"
echo "$OUT" | grep -q "will not take effect" \
    || { echo "FAIL: expected the 'will not take effect' warning for --ambit classic on a named subvolume"; exit 1; }
echo "OK: explicit --ambit classic on a named subvolume warns"
