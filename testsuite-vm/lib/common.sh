#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ISO_DIR="$SCRIPT_DIR/iso"
DISK_DIR="$SCRIPT_DIR/disks"
SSH_PORT="${SSH_PORT:-2222}"
SSH_DIR="$SCRIPT_DIR/.ssh"
SSH_KEY="$SSH_DIR/snapper-test"
VIRSH="virsh --connect qemu:///session"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY")

mkdir -p "$ISO_DIR" "$DISK_DIR"

die() { echo "FATAL: $*" >&2; exit 1; }
info() { printf "==> [%s] %s\n" "$(date +%H:%M:%S)" "$*"; }

ensure_ssh_key() {
    if [[ ! -f "$SSH_KEY" ]]; then
        info "Generating SSH key pair for VM access..."
        mkdir -p "$SSH_DIR"
        ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "snapper-test-vm"
    fi
}

download_iso() {
    local url="$1" file="$ISO_DIR/$2"
    if [[ -f "$file" ]]; then
        info "ISO already downloaded: $file"
        return
    fi
    info "Downloading ISO..."
    curl -fL -o "$file.part" "$url"
    mv "$file.part" "$file"
}

vm_exists() {
    $VIRSH dominfo "$1" &>/dev/null
}

vm_running() {
    [[ "$($VIRSH domstate "$1" 2>/dev/null)" == "running" ]]
}

wait_for_ssh() {
    local timeout="${1:-600}" mode="${2:-fatal}"
    info "Waiting for SSH on localhost:${SSH_PORT} (timeout ${timeout}s)..."
    local start=$SECONDS elapsed=0
    while (( SECONDS - start < timeout )); do
        elapsed=$(( SECONDS - start ))
        if ssh -q "${SSH_OPTS[@]}" -o ConnectTimeout=5 -p "$SSH_PORT" \
               root@localhost true 2>/dev/null; then
            info "SSH is up (${elapsed}s)."
            return 0
        fi
        printf "  ... %ds elapsed, VM state: %s\n" "$elapsed" "$($VIRSH domstate "$VM_NAME" 2>/dev/null || echo unknown)"
        sleep 5
    done
    [[ "$mode" == "soft" ]] && return 1
    die "SSH timeout after ${timeout}s"
}

vm_ssh() {
    ssh -q "${SSH_OPTS[@]}" -p "$SSH_PORT" root@localhost "$@"
}

sync_source() {
    info "Syncing source to VM..."
    rsync -a --delete \
        -e "ssh -q ${SSH_OPTS[*]} -p $SSH_PORT" \
        --exclude='.git' --exclude='autom4te.cache' \
        --exclude='testsuite-vm/iso' --exclude='testsuite-vm/disks' \
        --exclude='testsuite-vm/logs' --exclude='testsuite-vm/.ssh' \
        --exclude='.libs' --exclude='.deps' \
        --exclude='*.o' --exclude='*.lo' --exclude='*.la' \
        "$REPO_DIR/" "root@localhost:/root/snapper/"
}

# Evict the VM disk images and installer ISOs from the host page cache
# (root-free, via posix_fadvise DONTNEED). qemu's default writeback caching and
# readahead can leave ~10 GB of these files' pages resident; they are fully
# reclaimable (`available` stays high) but push `free` low enough to trip the
# host's background-task memory watchdog. Dropping them keeps `free` high without
# touching the running guest.
drop_vm_page_cache() {
    python3 - "$ISO_DIR" "$DISK_DIR" <<'PY' 2>/dev/null || true
import os, sys, glob
for d in sys.argv[1:]:
    for p in glob.glob(os.path.join(d, '*')):
        try:
            fd = os.open(p, os.O_RDONLY)
            os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
            os.close(fd)
        except OSError:
            pass
PY
}

build_in_vm() {
    # Restoring the clean-install snapshot also restores the guest clock to
    # snapshot-creation time, which may be hours behind wall-clock. rsync -a
    # preserves the host's (current) mtimes, so every source file then looks
    # "in the future" to the VM and maintainer-mode make loops forever
    # regenerating Makefiles (notably with automake >= 1.18 on Tumbleweed).
    # Sync the guest clock to the host before building so source mtimes are in
    # the past.
    info "Syncing VM clock to host before build..."
    vm_ssh "timedatectl set-ntp false 2>/dev/null; date -u -s '$(date -u '+%Y-%m-%d %H:%M:%S')' >/dev/null" || true

    # Run the build as a transient systemd unit *inside* the guest so it is
    # detached from this SSH session. If the host-side driver is killed (e.g. by
    # the background-task memory watchdog) mid-compile, the build keeps running
    # and we simply resume polling its sentinel file instead of losing it.
    info "Launching detached in-VM build..."
    local lib_expr='LIB=$(gcc -v 2>&1 | sed -n "s,.*--libdir=/usr/\([^ ]*\).*,\1,p"); LIB=${LIB:-lib}'
    vm_ssh "cat > /root/build-snapper.sh" <<SCRIPT
#!/bin/bash
exec >/root/build.log 2>&1
set -x
cd /root/snapper
rm -f /root/build.done
if make -f Makefile.repo all &&
   { $lib_expr; ./configure --prefix=/usr --libdir=/usr/\$LIB ${CONFIGURE_FLAGS:---enable-selinux --disable-ext4}; } &&
   make clean &&
   make -j\${MAKE_JOBS:-1} &&
   make install &&
   ldconfig; then
    echo ok > /root/build.done
else
    echo "fail:\$?" > /root/build.done
fi
SCRIPT
    vm_ssh 'rm -f /root/build.done /root/build.log; systemctl reset-failed snapper-build 2>/dev/null || true; systemd-run --unit=snapper-build --collect /bin/bash /root/build-snapper.sh' >/dev/null

    info "Waiting for in-VM build to finish (polling; dropping page cache each tick)..."
    local start=$SECONDS status=""
    while (( SECONDS - start < 2400 )); do
        drop_vm_page_cache
        status=$(vm_ssh 'cat /root/build.done 2>/dev/null || true')
        if [[ -n "$status" ]]; then
            if [[ "$status" == ok ]]; then
                info "Build complete (${SECONDS}s minus start = $(( SECONDS - start ))s)."
                return 0
            fi
            info "Build FAILED ($status); tail of build log:"
            vm_ssh 'tail -40 /root/build.log' || true
            die "Build failed in VM (status=$status)"
        fi
        sleep 20
    done
    die "Build timed out after $(( SECONDS - start ))s"
}

# True if snapshot $2 exists on VM $1. Captures the list first, then greps: piping
# virsh straight into `grep -q` lets grep short-circuit on an early match and
# SIGPIPE-kill virsh (exit 141), which `set -o pipefail` reports as a failure even
# though the snapshot was found.
has_snapshot() {
    local list
    list=$($VIRSH snapshot-list "$1" --name 2>/dev/null) || true
    grep -qx "$2" <<<"$list"
}

snapshot_vm() {
    local name="$1" snap_name="${2:-clean-install}"
    if has_snapshot "$name" "$snap_name"; then
        info "Snapshot '$snap_name' already exists."
        return
    fi
    info "Creating VM snapshot '$snap_name'..."
    $VIRSH snapshot-create-as "$name" "$snap_name"
}

restore_vm() {
    local name="$1" snap_name="${2:-clean-install}"
    info "Restoring VM to snapshot '$snap_name'..."
    $VIRSH snapshot-revert "$name" "$snap_name"
}

destroy_vm() {
    local name="$1"
    $VIRSH destroy "$name" 2>/dev/null || true
    $VIRSH undefine "$name" --snapshots-metadata 2>/dev/null || true
}
