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

build_in_vm() {
    info "Building snapper inside VM..."
    vm_ssh bash -ex <<SCRIPT
cd /root/snapper
make -f Makefile.repo all
LIB=\$(gcc -v 2>&1 | sed -n 's,.*--libdir=/usr/\([^ ]*\).*,\1,p')
LIB=\${LIB:-lib}
./configure --prefix=/usr --libdir=/usr/\$LIB ${CONFIGURE_FLAGS:---enable-selinux --disable-ext4}
make clean
make -j\$(nproc)
make install
ldconfig
SCRIPT
}

snapshot_vm() {
    local name="$1" snap_name="${2:-clean-install}"
    if $VIRSH snapshot-list "$name" --name 2>/dev/null | grep -q "^${snap_name}$"; then
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
