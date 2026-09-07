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

## Test engine and cases

`test` builds snapper once, snapshots the built VM, then runs the test **cases**
in `cases/`, each from a fresh restore of that snapshot (unit-test isolation),
and prints a TAP-style report. The engine (`lib/engine.sh`) is the only central
logic; scenarios are self-contained plug-ins.

Cases are grouped into **buckets** by the rollback method they target — there are
no per-case annotations, the folder decides applicability:

```
cases/
  _prelude.sh            # helpers prepended to every case
  all/                   # method-agnostic; run on every distro
  subvol-rename/         # run only where ROLLBACK_METHOD=subvol-rename
  set-default/           # run only where ROLLBACK_METHOD=set-default
```

The engine runs `all/` + the bucket matching the distro's declared
`ROLLBACK_METHOD` (from `config.sh` — ground truth, not auto-detected; snapper's
own detection is tested by `all/10-detect-ambit.sh`). Conventions inside a case:

- print `MARKER_FILE=<path>` → the engine reboots and asserts the file is **gone**
  (the rollback took effect); `PERSIST_MARKER=<path>` → asserts it **survives**.
- call `requires <cap>` (e.g. `requires selinux`) to self-skip where a capability
  is absent.

**Add a scenario**: drop one file in the right bucket. **Add a distro**: write its
plugin + `ROLLBACK_METHOD` — no case changes. **Move where a case runs**: move the
file between buckets.

## Distros and Rollback Methods

| Distro | SSH Port | Rollback Method | Installer |
|--------|----------|----------------|-----------|
| tumbleweed | 2222 | set-default | AutoYaST |
| debian13 | 2223 | subvol-rename | preseed |
| fedora43 | 2224 | subvol-rename | kickstart |
| ubuntu2604 | 2225 | subvol-rename | subiquity autoinstall |

Ubuntu's installer (subiquity/curtin) cannot create btrfs subvolumes, so its
profile installs a plain btrfs root and converts it to a named `@` subvolume in
`late-commands` (snapshot into `@`, set the default subvolume, fix fstab and
grub). The autoinstall config is delivered as a NoCloud "cidata" seed ISO.

## File Structure

```
run-all.sh                  # Run all distros in parallel
run-test.sh                 # Main test driver (install/build/test/ssh/destroy)
lib/common.sh               # Shared helpers (SSH, build, sync, snapshots)
lib/engine.sh               # Test engine: discovers cases, drives reboots, TAP report
cases/_prelude.sh           # Helpers prepended to every case
cases/all/                  # Method-agnostic cases (run on every distro)
cases/subvol-rename/        # Cases for named-subvolume roots
cases/set-default/          # Cases for default-subvolume roots
distros/<name>/config.sh    # VM config (name, ISO URL, SSH port, ROLLBACK_METHOD, build flags)
distros/<name>/*.xml|*.ks|*.cfg|user-data  # Unattended installer profile
distros/<name>/post-install.sh   # Optional post-install fixups
logs/                       # Serial logs and per-run logs
.ssh/                       # SSH key pair for VM access (auto-generated)
```

## Adding a New Distro

1. Create `distros/<name>/config.sh` with VM_NAME, ISO_URL, SSH_PORT,
   `ROLLBACK_METHOD` (`subvol-rename` or `set-default`), etc.
2. Add an installer profile (kickstart.ks, autoyast.xml, preseed.cfg, or a
   subiquity `user-data`). Use the `@@SSH_PUBKEY@@` placeholder for the SSH key.
3. Optionally add `post-install.sh` for post-install fixups.
4. Run `./run-test.sh <name> test` — every applicable case runs automatically.
