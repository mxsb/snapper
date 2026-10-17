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
    echo "  real [T]  Rebuild changed sources in the 'built' snapshot and run testsuite-real"
    echo "            (all tests, or test T) on a scratch btrfs at /testsuite"
    echo "            (REAL_SETUP=<command> runs in the source tree before make, e.g. to"
    echo "            reconfigure)"
    echo "  run S     Run host script S as root in a fresh restore of 'built'"
    echo "  provision C  Run command C in 'clean-install' and save it back (e.g. new build deps)"
    echo "  ssh       Open SSH session to VM"
    echo "  destroy   Remove VM and disk image"
    exit 1
}

[[ $# -lt 1 ]] && usage

DISTRO="$1"
COMMAND="${2:-test}"
shift $(( $# < 2 ? $# : 2 ))
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
    # Per-distro staging dir: run-all.sh installs distros in parallel, and two
    # distros of the same installer type must not overwrite each other's config
    # before virt-install injects it. The file names stay fixed since the kernel
    # args reference them inside the initrd.
    local stage_dir="$SCRIPT_DIR/.install/$DISTRO"
    mkdir -p "$stage_dir"
    local ks_tmp="$stage_dir/kickstart.ks"
    local ay_tmp="$stage_dir/autoyast.xml"
    local ps_tmp="$stage_dir/preseed.cfg"
    local seed_iso="$stage_dir/ubuntu-seed.iso"
    local location_arg="$ISO_DIR/$ISO_FILE"
    local disk_arg="path=$DISK_IMG,size=$VM_DISK,format=qcow2,cache=none"
    local boot_args=()

    if [[ -n "${CLOUD_IMAGE:-}" ]]; then
        # A ready-made cloud image (ISO_URL is the qcow2): boot it directly,
        # configured by cloud-init from a NoCloud "cidata" seed ISO.
        local seed_dir
        seed_dir=$(mktemp -d)
        prepare_installer_config "$DISTRO_DIR/user-data" "$seed_dir/user-data"
        : > "$seed_dir/meta-data"
        genisoimage -quiet -output "$seed_iso" -volid cidata -joliet -rock \
            "$seed_dir/user-data" "$seed_dir/meta-data"
        rm -rf "$seed_dir"
        cp --sparse=always "$ISO_DIR/$ISO_FILE" "$DISK_IMG"
        qemu-img resize -q "$DISK_IMG" "${VM_DISK}G"
        disk_arg="path=$DISK_IMG,format=qcow2,cache=none"
        boot_args=(--import)
        installer_args+=(--disk "path=$seed_iso,device=cdrom")
    elif [[ -f "$DISTRO_DIR/kickstart.ks" ]]; then
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

    # installer ISOs boot their installer, a cloud image (--import) itself
    [[ -n "${CLOUD_IMAGE:-}" ]] || boot_args=(--location "$location_arg" --noreboot)

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
        --disk "$disk_arg" \
        --os-variant "$OS_VARIANT" \
        --network passt,portForward="${SSH_PORT}:22" \
        --serial "file,path=$SERIAL_LOG" \
        "${boot_args[@]}" \
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

    # Detach the NoCloud seed CD before deleting it, otherwise restarting the
    # VM fails on the dangling reference (and the installed system must not
    # re-read the seed on later boots). A cloud image is still running here:
    # eject the medium live too, or the clean-install snapshot of the running
    # VM keeps referring to the deleted file and cannot be reverted.
    if [[ -f "$seed_iso" ]]; then
        if vm_running "$VM_NAME"; then
            $VIRSH change-media "$VM_NAME" "$seed_iso" --eject --live >/dev/null 2>&1 || true
        fi
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

    # A failed fixup leaves a half-configured VM: remove it like a failed
    # install, so that the next install starts over.
    fixup_failed() {
	info "$1 failed, cleaning up..."
	destroy_vm "$VM_NAME"
	rm -f "$DISK_IMG"
	die "$1 failed (see $LOG_FILE)"
    }

    if [[ -f "$DISTRO_DIR/post-install.sh" ]]; then
	info "Running post-install fixups..."
	vm_ssh bash -ex < "$DISTRO_DIR/post-install.sh" || fixup_failed "post-install.sh"
    fi

    # Setup that needs the system rebooted first (e.g. after converting the root
    # into a subvolume).
    if [[ -f "$DISTRO_DIR/post-reboot.sh" ]]; then
	info "Rebooting for post-reboot fixups..."
	vm_ssh systemctl reboot || true
	sleep 5
	wait_for_ssh 600 soft || fixup_failed "Reboot after post-install.sh"
	vm_ssh bash -ex < "$DISTRO_DIR/post-reboot.sh" || fixup_failed "post-reboot.sh"
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

# testsuite-real needs root and a scratch btrfs at /testsuite (CAUTION): run it
# in the 'built' snapshot with upstream's setup-and-run-all, after an
# incremental rebuild of the changed sources.
cmd_real() {
    has_snapshot "$VM_NAME" built || die "No 'built' snapshot; run '$0 $DISTRO test' first"
    restore_vm "$VM_NAME" built
    $VIRSH start "$VM_NAME" 2>/dev/null || true
    wait_for_ssh
    sync_source_incremental
    local test="${1:-}"
    vm_ssh "set -e; date -u -s '$(date -u '+%Y-%m-%d %H:%M:%S')' >/dev/null; cd /root/snapper
${REAL_SETUP:-true}
make -j\$(nproc) >/tmp/make.log 2>&1 || { tail -30 /tmp/make.log; exit 1; }
make -C testsuite-real ${test:-} >/tmp/make-real.log 2>&1 || { grep -E 'error' /tmp/make-real.log | head -30; exit 1; }
mkdir -p /etc/sysconfig; [ -e /etc/sysconfig/snapper ] || echo 'SNAPPER_CONFIGS=\"\"' > /etc/sysconfig/snapper
cd testsuite-real
# upstream's scratch setup: loop btrfs at /testsuite, config 'testsuite', nobody
if [ -n '${test:-}' ]; then ./setup-and-run-all setup >/tmp/setup.log 2>&1 || { cat /tmp/setup.log; exit 1; }; ./${test:-}
else ./setup-and-run-all 2>&1 | grep -v '^+'; fi"
}

cmd_run() {
    local script="${1:?usage: $0 $DISTRO run <script>}"
    has_snapshot "$VM_NAME" built || die "No 'built' snapshot; run '$0 $DISTRO test' first"
    restore_vm "$VM_NAME" built
    $VIRSH start "$VM_NAME" 2>/dev/null || true
    wait_for_ssh
    vm_ssh bash -s < "$script"
}

# The RAM snapshot restores the guest's network state from install time; if the
# host network changed since, its resolver is stale. Swap in a public one for
# the command, then save the result as the new 'clean-install' ('built' is
# dropped since it no longer derives from it).
cmd_provision() {
    local cmd="${1:?usage: $0 $DISTRO provision '<command>'}"
    restore_vm "$VM_NAME" clean-install
    $VIRSH start "$VM_NAME" 2>/dev/null || true
    wait_for_ssh
    vm_ssh "date -u -s '$(date -u '+%Y-%m-%d %H:%M:%S')' >/dev/null
mv /etc/resolv.conf /etc/resolv.conf.provision
echo nameserver 9.9.9.9 > /etc/resolv.conf
$cmd; rc=\$?
rm -f /etc/resolv.conf; mv /etc/resolv.conf.provision /etc/resolv.conf
exit \$rc"
    $VIRSH snapshot-delete "$VM_NAME" built >/dev/null 2>&1 || true
    $VIRSH snapshot-delete "$VM_NAME" clean-install >/dev/null
    $VIRSH snapshot-create-as "$VM_NAME" clean-install >/dev/null
    $VIRSH shutdown "$VM_NAME" >/dev/null 2>&1 || true
    info "clean-install updated."
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
    real)    cmd_real "$@" ;;
    run)     cmd_run "$@" ;;
    provision) cmd_provision "$@" ;;
    test)    cmd_test ;;
    ssh)     cmd_ssh ;;
    destroy) cmd_destroy ;;
    *)       usage ;;
esac
