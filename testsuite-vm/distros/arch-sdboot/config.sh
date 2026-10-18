VM_NAME="snapper-test-arch-sdboot"
SSH_PORT=2229
# The Arch profile booted with UEFI: post-install.sh installs systemd-boot with
# kernel-install entries instead of grub (the kernel command line comes from
# /etc/kernel/cmdline, not from the mounted root as with grub-mkconfig).
ISO_URL="https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
ISO_FILE="Arch-Linux-x86_64-cloudimg.qcow2"
CLOUD_IMAGE=1
BOOT_UEFI=1
VM_RAM=2048
VM_CPUS=2
VM_DISK=20
OS_VARIANT="archlinux"
CONFIGURE_FLAGS="--disable-selinux --disable-ext4"
ROLLBACK_METHOD="subvol-rename"
