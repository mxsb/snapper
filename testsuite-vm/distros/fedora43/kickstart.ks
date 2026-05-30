cmdline
firstboot --disable
eula --agreed

keyboard --vckeymap=us --xlayouts=us
lang en_US.UTF-8
timezone UTC --utc

network --bootproto=dhcp --activate
network --hostname=snapper-test

rootpw --plaintext snapper-test

selinux --permissive
firewall --disabled

url --url=https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Everything/x86_64/os/

bootloader --boot-drive=vda --append="console=tty0 console=ttyS0,115200n8"

zerombr
clearpart --all --initlabel --drives=vda
part biosboot --fstype=biosboot --size=1 --ondisk=vda
part /boot --fstype=ext4 --size=1024 --ondisk=vda
part btrfs.01 --fstype=btrfs --grow --ondisk=vda
btrfs none --label=fedora btrfs.01
btrfs / --subvol --name=root LABEL=fedora
btrfs /home --subvol --name=home LABEL=fedora

%packages
@core
openssh-server
snapper
btrfs-progs
acl
autoconf
automake
awk
boost-devel
btrfs-progs-devel
dbus-devel
diffutils
docbook-style-xsl
gcc-c++
gettext
glibc-langpack-de
glibc-langpack-fr
glibc-langpack-en
json-c-devel
libacl-devel
libmount-devel
libtool
libxml2-devel
libxslt
make
ncurses-devel
pam-devel
xz
rsync
%end

%post --interpreter=/bin/bash
set -euo pipefail

systemctl enable sshd

echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/99-snapper-test.conf
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config.d/99-snapper-test.conf

mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo "@@SSH_PUBKEY@@" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

snapper --no-dbus create-config /

echo "test ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/test
%end

poweroff
