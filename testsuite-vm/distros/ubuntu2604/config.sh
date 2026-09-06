VM_NAME="snapper-test-ubuntu2604"
SSH_PORT=2225
ISO_URL="https://releases.ubuntu.com/26.04/ubuntu-26.04.1-live-server-amd64.iso"
ISO_FILE="ubuntu-26.04.1-live-server-amd64.iso"
VM_RAM=2560
VM_CPUS=2
VM_DISK=20
# libosinfo may not know 26.04 yet; 25.10 gives the right virtio drivers.
OS_VARIANT="ubuntu25.10"
CONFIGURE_FLAGS="--disable-selinux --disable-ext4"
