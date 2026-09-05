#!/bin/bash
# Disable all YaST/AutoYaST services that would re-enter the installer on boot.
systemctl disable YaST2-Firstboot.service 2>/dev/null || true
systemctl disable YaST2-Second-Stage.service 2>/dev/null || true
systemctl disable autoyast-initscripts.service 2>/dev/null || true
rm -f /var/lib/YaST2/runme_at_boot /var/lib/YaST2/reconfig_system
rm -f /var/lib/YaST2/second_stage_failed
rm -f /etc/install.inf

# Note: do NOT set "UsePAM no" here. With the split sshd-session (OpenSSH 9.8+)
# it makes sshd reject root as "account is locked", breaking all logins. PAM is
# enabled in setup-ssh.sh instead; logind is up and login is instant.

hostnamectl set-hostname snapper-test
