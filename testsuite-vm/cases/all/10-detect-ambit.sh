# Snapper's own ambit auto-detection must match the distro's declared method.
# (The engine trusts the declared ROLLBACK_METHOD for bucket selection; this
# case is what actually tests detection, so a detection bug fails loudly.)
echo "=== detect-ambit: declared method is '$ROLLBACK_METHOD' ==="
ensure_config

PRE=$(snapper --no-dbus -c root create -d "detect-ambit" -p)
OUT=$(snapper --no-dbus -c root rollback "$PRE" 2>&1) || true
echo "$OUT"
AMBIT=$(echo "$OUT" | sed -n 's/.*Ambit is \([a-z-]*\).*/\1/p' | head -1)
echo "snapper detected ambit: '$AMBIT'"

if [ "$ROLLBACK_METHOD" = "subvol-rename" ]; then
    [ "$AMBIT" = "subvol-rename" ] || { echo "FAIL: expected subvol-rename, got '$AMBIT'"; exit 1; }
else
    case "$AMBIT" in
        classic|transactional) ;;
        *) echo "FAIL: expected classic/transactional for set-default, got '$AMBIT'"; exit 1 ;;
    esac
fi
echo "OK: detected ambit matches the declared rollback method"
