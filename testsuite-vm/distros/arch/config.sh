VM_NAME="snapper-test-arch"
SSH_PORT=2228
# The official cloud image (arch-boxes): btrfs root, grub, mkinitcpio, cloud-init.
# Rolling release, so always the latest image.
ISO_URL="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
ISO_FILE="Arch-Linux-x86_64-cloudimg.qcow2"
CLOUD_IMAGE=1
VM_RAM=2048
VM_CPUS=2
VM_DISK=20
OS_VARIANT="archlinux"
CONFIGURE_FLAGS="--disable-selinux --disable-ext4"
ROLLBACK_METHOD="subvol-rename"
