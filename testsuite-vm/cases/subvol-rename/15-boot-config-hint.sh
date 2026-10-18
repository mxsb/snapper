# Until the reboot the old root keeps running under its new name, and grub's
# 10_linux takes rootflags=subvol= from the running root: update-grub (run by
# kernel updates on Debian/Ubuntu) before the reboot would boot the old root
# again. That cannot be avoided by the rename, so the rollback must say it.
echo "=== the rollback warns about regenerating the boot configuration ==="
ensure_config

PRE=$(snapper --no-dbus -c root create -d "boot-config-hint-target" -p)
OUT=$(snapper --no-dbus -c root rollback "$PRE" 2>&1)
echo "$OUT"
echo "$OUT" | grep -q "boot loader configuration" \
    || { echo "FAIL: no hint about regenerating the boot loader configuration"; exit 1; }
echo "OK: the rollback says to reboot before the boot configuration is regenerated"
