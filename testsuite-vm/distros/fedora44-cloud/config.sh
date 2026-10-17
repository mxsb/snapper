VM_NAME="snapper-test-fedora44-cloud"
SSH_PORT=2227
ISO_URL="https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/iso/Fedora-Everything-netinst-x86_64-44-1.7.iso"
ISO_FILE="Fedora-Everything-netinst-x86_64-44-1.7.iso"
VM_RAM=2048
VM_CPUS=2
VM_DISK=20
# osinfo-db does not know fedora44 yet; the fedora43 variant only picks device defaults
OS_VARIANT="fedora43"
CONFIGURE_FLAGS="--enable-selinux --disable-ext4"
ROLLBACK_METHOD="subvol-rename"
