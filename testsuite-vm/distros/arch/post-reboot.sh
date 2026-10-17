# The system must now boot the @ subvolume, by name.
echo "cmdline: $(cat /proc/cmdline)"
echo "fstab /: $(awk '!/^[[:space:]]*#/ && $2=="/" {print $4}' /etc/fstab)"
findmnt -n -o SOURCE,OPTIONS /
awk '$2=="/" {print $4}' /proc/mounts | tr ',' '\n' | grep -qx 'subvol=/@' \
    || { echo "not booted from the @ subvolume"; exit 1; }
