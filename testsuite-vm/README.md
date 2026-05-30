# VM Integration Tests

End-to-end rollback tests using QEMU/libvirt VMs. Each distro gets a full
unattended install, builds snapper from the host source tree, performs a
`snapper rollback`, reboots, and verifies the rollback took effect.

## Requirements

- `qemu-kvm`, `libvirt`, `virt-install`, `virt-xml`, `passt`, `rsync`
- No root needed — everything runs in `qemu:///session` mode

## Quick Start

```bash
# Run all distros in parallel (installs on first run, ~15 min; subsequent runs ~2.5 min):
./run-all.sh

# Run a single distro:
./run-test.sh tumbleweed test

# Other commands:
./run-test.sh <distro> install   # Create VM from ISO (first time only)
./run-test.sh <distro> build     # Sync source + build snapper in VM
./run-test.sh <distro> ssh       # Open SSH session to VM
./run-test.sh <distro> destroy   # Remove VM and disk image
```

## Distros and Rollback Methods

| Distro | SSH Port | Rollback Method | Installer |
|--------|----------|----------------|-----------|
| tumbleweed | 2222 | set-default | AutoYaST |
| debian13 | 2223 | subvol-rename | preseed |
| fedora43 | 2224 | subvol-rename | kickstart |

## File Structure

```
run-all.sh                  # Run all distros in parallel
run-test.sh                 # Main test driver (install/build/test/ssh/destroy)
test-rollback.sh            # Runs inside the VM: create snapshot, rollback, verify
lib/common.sh               # Shared helpers (SSH, build, sync, snapshots)
distros/<name>/config.sh    # VM config (name, ISO URL, SSH port, build flags)
distros/<name>/*.xml|*.ks|*.cfg  # Unattended installer profile
distros/<name>/post-install.sh   # Optional post-install fixups
logs/                       # Serial logs and per-run logs
.ssh/                       # SSH key pair for VM access (auto-generated)
```

## Adding a New Distro

1. Create `distros/<name>/config.sh` with VM_NAME, ISO_URL, SSH_PORT, etc.
2. Add an installer profile (kickstart.ks, autoyast.xml, or preseed.cfg).
   Use `@@SSH_PUBKEY@@` placeholder for the SSH public key.
3. Optionally add `post-install.sh` for post-install fixups.
4. Run `./run-test.sh <name> test`.
