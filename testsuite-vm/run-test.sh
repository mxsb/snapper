#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    echo "Usage: $0 <distro> [command]"
    echo ""
    echo "Distros: $(ls "$SCRIPT_DIR/distros/" | tr '\n' ' ')"
    echo ""
    echo "Commands:"
    echo "  test      Build snapper and run rollback test (default, auto-installs if needed)"
    echo "  extras    Build snapper and run extra scenario tests (quota, SELinux enforcing)"
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
    else
        die "No installer config found in $DISTRO_DIR"
    fi

    trap 'info "Install failed, cleaning up..."; destroy_vm "$VM_NAME"; rm -f "$DISK_IMG" "$ks_tmp" "$ay_tmp" "$ps_tmp"' ERR

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
        --disk "path=$DISK_IMG,size=$VM_DISK,format=qcow2" \
        --os-variant "$OS_VARIANT" \
        --location "$ISO_DIR/$ISO_FILE" \
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

    rm -f "$ks_tmp" "$ay_tmp" "$ps_tmp"
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

run_rollback_script() {
    local script="$1"
    local output
    output=$(vm_ssh bash -s < "$SCRIPT_DIR/$script")
    echo "$output"

    MARKER=$(echo "$output" | grep '^MARKER_FILE=' | cut -d= -f2)
    [[ -n "$MARKER" ]] || die "Could not extract marker file path from $script output"
}

reboot_and_verify_marker() {
    local marker="$1" what="$2"

    info "Rebooting VM to verify $what..."
    : > "$SERIAL_LOG"
    vm_ssh systemctl reboot || true
    sleep 5
    if ! wait_for_ssh 600 soft; then
        info "Post-rollback boot did not come up — last serial output:"
        tail -n 40 "$SERIAL_LOG" 2>/dev/null || true
        die "FAIL: SSH did not return after $what reboot (see $SERIAL_LOG)"
    fi

    if vm_ssh test -f "$marker"; then
        die "FAIL: $marker still exists after reboot — $what did not take effect"
    fi
    info "PASS: $marker is gone after reboot. Verified: $what."
}

cmd_test() {
    if ! $VIRSH snapshot-list "$VM_NAME" --name 2>/dev/null | grep -q '^clean-install$'; then
        info "No clean-install snapshot found, running install first..."
        cmd_install
    fi

    restore_vm "$VM_NAME" "clean-install"
    $VIRSH start "$VM_NAME" 2>/dev/null || true
    wait_for_ssh
    sync_source
    build_in_vm

    info "Running rollback test..."
    run_rollback_script test-rollback.sh
    reboot_and_verify_marker "$MARKER" "rollback"

    info "Running second rollback cycle (repeated rollback, .rollback.N collision)..."
    run_rollback_script test-rollback2.sh
    reboot_and_verify_marker "$MARKER" "second rollback"

    info "Running third rollback cycle (ROLLBACK_BACKUP_LIMIT retention)..."
    run_rollback_script test-rollback3.sh
    reboot_and_verify_marker "$MARKER" "third rollback"

    info "Running transactional ambit regression test..."
    vm_ssh bash -s < "$SCRIPT_DIR/test-rollback-transactional.sh"

    $VIRSH shutdown "$VM_NAME" 2>/dev/null || true
}

cmd_ssh() {
    vm_running "$VM_NAME" || $VIRSH start "$VM_NAME"
    wait_for_ssh
    ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" root@localhost
}

# Extra scenario tests that each need a clean, freshly built system (they change
# global state - quota, SELinux mode - and do their own single rollback, so they
# are not part of the reboot-driven cycles in cmd_test). Build once, snapshot,
# and run each from that snapshot.
cmd_extras() {
    if ! $VIRSH snapshot-list "$VM_NAME" --name 2>/dev/null | grep -q '^clean-install$'; then
        info "No clean-install snapshot found, running install first..."
        cmd_install
    fi

    restore_vm "$VM_NAME" "clean-install"
    $VIRSH start "$VM_NAME" 2>/dev/null || true
    wait_for_ssh
    sync_source
    build_in_vm

    $VIRSH snapshot-delete "$VM_NAME" extras-built >/dev/null 2>&1 || true
    $VIRSH snapshot-create-as "$VM_NAME" extras-built >/dev/null

    run_extra() {
        local script="$1" what="$2"
        info "Running extra test: $what..."
        restore_vm "$VM_NAME" extras-built
        $VIRSH start "$VM_NAME" 2>/dev/null || true
        wait_for_ssh
        vm_ssh bash -s < "$SCRIPT_DIR/$script"
        info "PASS: $what"
    }

    run_extra test-rollback-quota.sh "btrfs quota rollback"
    run_extra test-rollback-selinux.sh "SELinux enforcing rollback"

    $VIRSH snapshot-delete "$VM_NAME" extras-built >/dev/null 2>&1 || true
    $VIRSH shutdown "$VM_NAME" 2>/dev/null || true
    info "Extra scenario tests passed."
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
    extras)  cmd_extras ;;
    ssh)     cmd_ssh ;;
    destroy) cmd_destroy ;;
    *)       usage ;;
esac
