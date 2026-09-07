#!/bin/bash
# Rollback test engine.
#
# Scenarios are self-contained case scripts under cases/, grouped into buckets by
# the rollback method they target:
#
#   cases/all/            run on every distro (method-agnostic)
#   cases/subvol-rename/  run only where ROLLBACK_METHOD=subvol-rename
#   cases/set-default/    run only where ROLLBACK_METHOD=set-default
#
# The distro's config.sh declares ROLLBACK_METHOD (the ground truth used to pick
# the bucket - snapper's own auto-detection is exercised by a case, not trusted
# here). The engine builds snapper once, snapshots 'built', then runs each
# applicable case from a fresh restore of that snapshot for unit-test isolation.
#
# There are no per-case metadata annotations. Applicability is the folder; a case
# that needs reboot verification prints "MARKER_FILE=<path>" (the engine reboots
# and asserts the file is gone); a case that needs a capability calls
# `requires <cap>` from the prelude, which prints "SKIP: ..." and exits 0.

CASES_DIR="$SCRIPT_DIR/cases"
PRELUDE="$CASES_DIR/_prelude.sh"

# engine_reboot_verify <gone_marker> <persist_marker> <name>
# Reboots the VM, then: a non-empty gone_marker must be ABSENT (the rollback
# discarded post-snapshot changes) and a non-empty persist_marker must be
# PRESENT (the rollback preserved data / the system boots on the new default).
engine_reboot_verify() {
    local gone="$1" persist="$2" name="$3"
    : > "$SERIAL_LOG"
    vm_ssh systemctl reboot || true
    sleep 5
    if ! wait_for_ssh 600 soft; then
        echo "    FAIL: SSH did not return after reboot ($name)"
        return 1
    fi
    if [ -n "$gone" ] && vm_ssh test -f "$gone"; then
        echo "    FAIL: $gone still present after reboot ($name) -- rollback did not take effect"
        return 1
    fi
    if [ -n "$persist" ] && ! vm_ssh test -f "$persist"; then
        echo "    FAIL: $persist missing after reboot ($name) -- expected it to survive"
        return 1
    fi
    return 0
}

run_engine() {
    : "${ROLLBACK_METHOD:?config.sh must set ROLLBACK_METHOD (subvol-rename|set-default)}"
    local method="$ROLLBACK_METHOD"
    if [[ "$method" != "subvol-rename" && "$method" != "set-default" ]]; then
        die "Unknown ROLLBACK_METHOD '$method' (expected subvol-rename or set-default)"
    fi
    [[ -f "$PRELUDE" ]] || die "Missing $PRELUDE"

    if ! has_snapshot "$VM_NAME" clean-install; then
        info "No clean-install snapshot found, installing first..."
        cmd_install
    fi

    # SKIP_BUILD=1 reuses an existing 'built' snapshot (fast iteration on cases,
    # no ~10 min rebuild). Fails loudly if there is no 'built' snapshot to reuse.
    if [[ -n "${SKIP_BUILD:-}" ]]; then
        has_snapshot "$VM_NAME" built \
            || die "SKIP_BUILD set but no 'built' snapshot exists; run once without it first"
        info "SKIP_BUILD set: reusing existing 'built' snapshot."
    else
        restore_vm "$VM_NAME" "clean-install"
        $VIRSH start "$VM_NAME" 2>/dev/null || true
        wait_for_ssh
        sync_source
        build_in_vm

        # Snapshot the freshly built system; each case restores it for isolation.
        $VIRSH snapshot-delete "$VM_NAME" built >/dev/null 2>&1 || true
        $VIRSH snapshot-create-as "$VM_NAME" built >/dev/null
    fi

    info "Rollback method (declared): $method"

    # List every case (all buckets) so the report shows what ran and what was
    # skipped for this distro. Order: all/, subvol-rename/, set-default/.
    local cases=()
    local d
    for d in all subvol-rename set-default; do
        [[ -d "$CASES_DIR/$d" ]] || continue
        local f
        for f in "$CASES_DIR/$d"/[0-9]*.sh; do
            [[ -e "$f" ]] && cases+=("$f")
        done
    done
    [[ ${#cases[@]} -gt 0 ]] || die "No case scripts found under $CASES_DIR/"

    local n=0 pass=0 fail=0 skip=0 failed=""
    local case
    for case in "${cases[@]}"; do
        n=$((n + 1))
        local rel name bucket
        rel="${case#"$CASES_DIR"/}"
        name="$rel"
        bucket="${rel%%/*}"

        # A case applies if it's method-agnostic (all/) or matches this method.
        if [[ "$bucket" != "all" && "$bucket" != "$method" ]]; then
            echo "ok $n - $name # SKIP not applicable to method '$method'"
            skip=$((skip + 1)); continue
        fi

        drop_vm_page_cache
        restore_vm "$VM_NAME" "built"
        $VIRSH start "$VM_NAME" 2>/dev/null || true
        wait_for_ssh

        info "--- case $n: $name ---"
        local out rc marker persist reason phase
        # A case runs once; a phase may print ENGINE_REBOOT to have the engine
        # reboot the VM and re-run the case (multi-cycle scenarios persist their
        # own phase across the reboot). max_phases caps the cycles.
        local max_phases=8
        for (( phase=0; phase<=max_phases; phase++ )); do
            out=$(cat "$PRELUDE" "$case" | vm_ssh "ROLLBACK_METHOD='$method' bash -s" 2>&1) && rc=0 || rc=$?
            echo "$out" | sed 's/^/    | /'

            if grep -q '^SKIP:' <<<"$out"; then
                reason=$(sed -n 's/^SKIP:[[:space:]]*//p' <<<"$out" | head -1)
                echo "ok $n - $name # SKIP ${reason:-self-skipped}"
                skip=$((skip + 1)); continue 2
            fi
            if [ "$rc" -ne 0 ]; then
                echo "not ok $n - $name [exit $rc]"
                fail=$((fail + 1)); failed="$failed $name"; continue 2
            fi

            # Multi-cycle: reboot and re-run the case for the next phase.
            if grep -q '^ENGINE_REBOOT$' <<<"$out"; then
                if (( phase >= max_phases )); then
                    echo "not ok $n - $name (exceeded $max_phases reboot phases)"
                    fail=$((fail + 1)); failed="$failed $name"; continue 2
                fi
                info "    (phase $phase requested ENGINE_REBOOT; rebooting)"
                : > "$SERIAL_LOG"
                vm_ssh systemctl reboot || true
                sleep 5
                if ! wait_for_ssh 600 soft; then
                    echo "not ok $n - $name (SSH did not return after ENGINE_REBOOT, phase $phase)"
                    fail=$((fail + 1)); failed="$failed $name"; continue 2
                fi
                continue   # re-run the case (next phase)
            fi

            # Terminal phase: optional reboot marker verification.
            marker=$(sed -n 's/^MARKER_FILE=//p' <<<"$out" | head -1)
            persist=$(sed -n 's/^PERSIST_MARKER=//p' <<<"$out" | head -1)
            if [ -n "$marker" ] || [ -n "$persist" ]; then
                if ! engine_reboot_verify "$marker" "$persist" "$name"; then
                    echo "not ok $n - $name (reboot verification failed)"
                    fail=$((fail + 1)); failed="$failed $name"; continue 2
                fi
            fi
            echo "ok $n - $name"
            pass=$((pass + 1)); continue 2
        done
    done

    $VIRSH shutdown "$VM_NAME" 2>/dev/null || true
    echo "1..$n"
    info "RESULTS ($DISTRO): $pass passed, $skip skipped, $fail failed (of $n)"
    if [ "$fail" -ne 0 ]; then
        info "Failed cases:$failed"
        return 1
    fi
    return 0
}
