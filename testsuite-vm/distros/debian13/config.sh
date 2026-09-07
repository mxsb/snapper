VM_NAME="snapper-test-debian13"
SSH_PORT=2223
VM_RAM=2048
VM_CPUS=2
VM_DISK=20
OS_VARIANT="debian13"
CONFIGURE_FLAGS="--disable-selinux --disable-ext4"
ROLLBACK_METHOD="subvol-rename"

# Debian removes superseded point releases from .../current/, so a pinned
# ISO filename 404s after the next point release. Resolve the current
# netinst image from the directory listing, falling back to a known name if
# the lookup fails (e.g. offline).
_DEBIAN_ISO_DIR="https://cdimage.debian.org/cdimage/release/current/amd64/iso-cd"
ISO_FILE="$(curl -sL "$_DEBIAN_ISO_DIR/" 2>/dev/null \
    | grep -oE 'debian-13\.[0-9]+\.[0-9]+-amd64-netinst\.iso' | sort -uV | tail -1)"
ISO_FILE="${ISO_FILE:-debian-13.6.0-amd64-netinst.iso}"
ISO_URL="$_DEBIAN_ISO_DIR/$ISO_FILE"
