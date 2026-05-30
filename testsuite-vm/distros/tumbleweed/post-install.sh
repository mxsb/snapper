#!/bin/bash
# Disable all YaST/AutoYaST services that would re-enter the installer on boot.
systemctl disable YaST2-Firstboot.service 2>/dev/null || true
systemctl disable YaST2-Second-Stage.service 2>/dev/null || true
systemctl disable autoyast-initscripts.service 2>/dev/null || true
rm -f /var/lib/YaST2/runme_at_boot /var/lib/YaST2/reconfig_system
rm -f /var/lib/YaST2/second_stage_failed
rm -f /etc/install.inf

# pam_systemd's varlink call to systemd-logind times out (120s) in minimal VMs.
# Disable PAM for sshd since we only use key-based auth.
mkdir -p /etc/ssh/sshd_config.d
grep -q 'UsePAM no' /etc/ssh/sshd_config.d/99-snapper-test.conf 2>/dev/null || \
    echo "UsePAM no" >> /etc/ssh/sshd_config.d/99-snapper-test.conf

hostnamectl set-hostname snapper-test
