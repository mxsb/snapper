# The plugin contract of a subvol-rename rollback (doc/rollback.txt, snapper(8)):
# the plugins get the documented arguments, and what the rollback script
# (/usr/lib/snapper/plugins/rollback, old and new root) writes into the new
# root boots, although the root is a copy of that snapshot.
echo "=== plugin contract ==="
ensure_config

LOG=/run/plugin-contract.log   # tmpfs, checked before the reboot
mkdir -p /usr/lib/snapper/plugins
cat > /usr/lib/snapper/plugins/50-contract <<'EOF'
#!/bin/sh
echo "$*" >> /run/plugin-contract.log
EOF
cat > /usr/lib/snapper/plugins/rollback <<'EOF'
#!/bin/sh
[ $# -eq 2 ] && [ -d "$2" ] && echo "written by the rollback script" > "$2/plugin-rollback-marker"
exit 0
EOF
chmod +x /usr/lib/snapper/plugins/50-contract /usr/lib/snapper/plugins/rollback

PRE=$(snapper --no-dbus -c root create -d "plugin-contract-target" -p)
emit_marker          # created AFTER $PRE, so the rollback removes it
: > "$LOG"
OUT=$(snapper --no-dbus -c root rollback "$PRE")
echo "$OUT"
BACKUP=$(echo "$OUT" | sed -n 's/^Creating read-only snapshot.*(Snapshot \([0-9]*\)\.)$/\1/p')
COPY=$(echo "$OUT" | sed -n 's/^Creating read-write snapshot.*(Snapshot \([0-9]*\)\.)$/\1/p')
echo "backup $BACKUP, writable copy $COPY"; cat "$LOG"

for line in "set-default-snapshot-pre / btrfs $COPY" "set-default-snapshot-post / btrfs $COPY" \
            "rollback / btrfs $BACKUP $COPY" "rollback-post / btrfs $BACKUP $COPY"; do
    grep -qx "$line" "$LOG" || { echo "FAIL: plugin not called as '$line'"; exit 1; }
done
echo "PERSIST_MARKER=/plugin-rollback-marker"
echo "plugins called as documented; engine verifies the rollback script's file boots"
