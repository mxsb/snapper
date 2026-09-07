#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/engine.sh"

usage() {
    echo "Usage: $0 <distro> [command]"
    echo ""
    echo "Distros: $(ls "$SCRIPT_DIR/distros/" | tr '\n' ' ')"
    echo ""
    echo "Commands:"
    echo "  test      Build snapper and run the rollback test engine (default, auto-installs if needed)"
    echo "  install   Create VM from ISO (first time only)"
    echo "  build     Copy source from host and build snapper in VM"
    echo "  ssh       Open SSH session to VM"
    echo "  destroy   Remove VM and disk image"
    exit 1
}

[[ $# -lt 1 ]] && usage

DISTRO="$1"
COMMAND="${2:-test}"
DISTRO_DIR="$SCRIPT_DIR/distros/$DISTRO"

[[ -d "$DISTRO_DIR" ]] || die "Unknown distro: $DISTRO (no $DISTRO_DIR)"

source "$DISTRO_DIR/config.sh"

DISK_IMG="$DISK_DIR/${VM_NAME}.qcow2"

LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
SERIAL_LOG="$LOG_DIR/${DISTRO}-serial.log"
LOG_FILE="$LOG_DIR/${DISTRO}-${COMMAND}-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
ln -sf "$(basename "$LOG_FILE")" "$LOG_DIR/${DISTRO}-${COMMAND}-latest.log"

prepare_installer_config() {
    local ks_src="$1" ks_out="$2"
    ensure_ssh_key
    local pubkey
    pubkey=$(cat "$SSH_KEY.pub")
    sed "s|@@SSH_PUBKEY@@|${pubkey}|g" "$ks_src" > "$ks_out"
}

cmd_install() {
    if vm_exists "$VM_NAME"; then
        info "VM '$VM_NAME' already exists. Use 'destroy' first to reinstall."
        return
    fi

    download_iso "$ISO_URL" "$ISO_FILE"
    ensure_ssh_key

    info "Creating VM '$VM_NAME'..."

    local installer_args=()
    local ks_tmp="$SCRIPT_DIR/kickstart.ks"
    local ay_tmp="$SCRIPT_DIR/autoyast.xml"
    local ps_tmp="$SCRIPT_DIR/preseed.cfg"
    local seed_iso="$SCRIPT_DIR/ubuntu-seed.iso"
    local location_arg="$ISO_DIR/$ISO_FILE"

    if [[ -f "$DISTRO_DIR/kickstart.ks" ]]; then
        prepare_installer_config "$DISTRO_DIR/kickstart.ks" "$ks_tmp"
        info "Prepared kickstart: $ks_tmp ($(wc -c < "$ks_tmp") bytes)"
        installer_args+=(--initrd-inject="$ks_tmp")
        installer_args+=(--extra-args="inst.ks=file:/kickstart.ks inst.stage2=cdrom console=ttyS0 nameserver=9.9.9.9")
    elif [[ -f "$DISTRO_DIR/autoyast.xml" ]]; then
        prepare_installer_config "$DISTRO_DIR/autoyast.xml" "$ay_tmp"
        info "Prepared autoyast: $ay_tmp ($(wc -c < "$ay_tmp") bytes)"
        installer_args+=(--initrd-inject="$ay_tmp")
        installer_args+=(--extra-args="autoyast=file:///autoyast.xml ${INSTALL_URL:+install=$INSTALL_URL} console=ttyS0 ifcfg=*=dhcp,NETCONFIG_DNS_STATIC_SERVERS=9.9.9.9 manual=0 linuxrc.debug=4,trace linemode=1 linuxrc.log=/dev/console")
    elif [[ -f "$DISTRO_DIR/preseed.cfg" ]]; then
        prepare_installer_config "$DISTRO_DIR/preseed.cfg" "$ps_tmp"
        info "Prepared preseed: $ps_tmp ($(wc -c < "$ps_tmp") bytes)"
        installer_args+=(--initrd-inject="$ps_tmp")
        installer_args+=(--extra-args="auto=true priority=critical file=/preseed.cfg console=ttyS0 nameserver=9.9.9.9")
    elif [[ -f "$DISTRO_DIR/user-data" ]]; then
        # Ubuntu subiquity autoinstall via a NoCloud "cidata" seed ISO plus the
        # "autoinstall" kernel arg. The live-server ISO boots its casper
        # kernel/initrd, so point --location at those explicitly.
        local seed_dir
        seed_dir=$(mktemp -d)
        prepare_installer_config "$DISTRO_DIR/user-data" "$seed_dir/user-data"
        : > "$seed_dir/meta-data"
        info "Prepared autoinstall user-data ($(wc -c < "$seed_dir/user-data") bytes)"
        genisoimage -quiet -output "$seed_iso" -volid cidata -joliet -rock \
            "$seed_dir/user-data" "$seed_dir/meta-data"
        rm -rf "$seed_dir"
        location_arg="$ISO_DIR/$ISO_FILE,kernel=casper/vmlinuz,initrd=casper/initrd"
        installer_args+=(--disk "path=$seed_iso,device=cdrom")
        installer_args+=(--extra-args="autoinstall console=ttyS0")
    else
        die "No installer config found in $DISTRO_DIR"
    fi

    trap 'info "Install failed, cleaning up..."; destroy_vm "$VM_NAME"; rm -f "$DISK_IMG" "$ks_tmp" "$ay_tmp" "$ps_tmp" "$seed_iso"' ERR

    : > "$SERIAL_LOG"
    local console_args=(--graphics none --console pty,target_type=serial)
    if [[ ! -t 0 ]]; then
        console_args=(--graphics none --noautoconsole)
    fi

    virt-install \
        --connect qemu:///session \
        --name "$VM_NAME" \
        --ram "$VM_RAM" \
        --vcpus "$VM_CPUS" \
        --disk "path=$DISK_IMG,size=$VM_DISK,format=qcow2,cache=none" \
        --os-variant "$OS_VARIANT" \
        --location "$location_arg" \
        --network passt,portForward="${SSH_PORT}:22" \
        --serial "file,path=$SERIAL_LOG" \
        --noreboot \
        "${console_args[@]}" \
        "${installer_args[@]}"

    if [[ ! -t 0 ]]; then
        info "Install running headless, waiting for VM to shut off or SSH to come up..."
        local start=$SECONDS
        while vm_running "$VM_NAME"; do
            if ssh -q "${SSH_OPTS[@]}" -o ConnectTimeout=5 -p "$SSH_PORT" \
                   root@localhost true 2>/dev/null; then
                info "VM booted into installed system (${SECONDS}s)."
                break
            fi
            printf "  ... %ds elapsed\n" "$(( SECONDS - start ))"
            sleep 30
        done
    fi

    # Detach the Ubuntu autoinstall seed CD before deleting it, otherwise
    # restarting the VM fails on the dangling reference (and the installed
    # system must not re-read the NoCloud seed on later boots).
    if [[ -f "$seed_iso" ]]; then
        virt-xml --connect qemu:///session "$VM_NAME" --remove-device --disk "path=$seed_iso" 2>/dev/null || true
    fi
    rm -f "$ks_tmp" "$ay_tmp" "$ps_tmp" "$seed_iso"
    trap - ERR

    # AutoYaST's <final_halt> runs a "zzz_halt" init script at the end of its
    # first-boot second stage, powering the VM off. The system is fully
    # installed by then but needs another boot to come up normally. We expect
    # at most two boots (the second-stage halt, then a clean boot), so allow a
    # small number of (re)starts and fail loudly if the VM keeps halting.
    local max_starts=3 starts=0
    info "Booting installed system (may halt once for AutoYaST second stage)..."
    local boot_start=$SECONDS
    while (( SECONDS - boot_start < 900 )); do
        if ! vm_running "$VM_NAME"; then
            # pre-increment: (( starts++ )) evaluates to 0 on the first pass and
            # would abort the script under `set -e`.
            (( ++starts ))
            if (( starts > max_starts )); then
                die "VM halted $((starts - 1)) times without becoming SSH-reachable (see $SERIAL_LOG)"
            fi
            info "VM is shut off; start attempt $starts/$max_starts..."
            $VIRSH start "$VM_NAME"
        fi
        if ssh -q "${SSH_OPTS[@]}" -o ConnectTimeout=5 -p "$SSH_PORT" \
               root@localhost true 2>/dev/null; then
            info "SSH is up ($(( SECONDS - boot_start ))s)."
            break
        fi
        sleep 5
    done
    vm_ssh true 2>/dev/null || die "SSH did not come up after install (see $SERIAL_LOG)"

    if [[ -f "$DISTRO_DIR/post-install.sh" ]]; then
	info "Running post-install fixups..."
	vm_ssh bash -ex < "$DISTRO_DIR/post-install.sh"
    fi

    snapshot_vm "$VM_NAME" "clean-install"
    info "VM ready. Clean snapshot saved."
}

cmd_build() {
    vm_running "$VM_NAME" || $VIRSH start "$VM_NAME"
    wait_for_ssh

    sync_source
    build_in_vm
    info "Build complete."
}

# Build snapper and run the pluggable rollback test engine (lib/engine.sh):
# discovers cases/ and runs those applicable to this distro's ROLLBACK_METHOD,
# each from a fresh 'built' snapshot, with a TAP-style report.
cmd_test() {
    run_engine
}

cmd_ssh() {
    vm_running "$VM_NAME" || $VIRSH start "$VM_NAME"
    wait_for_ssh
    ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" root@localhost
}

cmd_destroy() {
    destroy_vm "$VM_NAME"
    rm -f "$DISK_IMG"
    info "VM '$VM_NAME' destroyed."
}

case "$COMMAND" in
    install) cmd_install ;;
    build)   cmd_build ;;
    test)    cmd_test ;;
    ssh)     cmd_ssh ;;
    destroy) cmd_destroy ;;
    *)       usage ;;
esac
