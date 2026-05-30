#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND="${1:-test}"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

DISTROS=($(ls "$SCRIPT_DIR/distros/"))
PIDS=()
RESULTS=()

for distro in "${DISTROS[@]}"; do
    echo "==> Starting $distro $COMMAND (log: logs/${distro}-${COMMAND}-latest.log)"
    "$SCRIPT_DIR/run-test.sh" "$distro" "$COMMAND" > /dev/null 2>&1 &
    PIDS+=($!)
    RESULTS+=("pending")
done

echo "==> Waiting for ${#DISTROS[@]} distros..."

FAILED=0
for i in "${!DISTROS[@]}"; do
    if wait "${PIDS[$i]}"; then
        RESULTS[$i]="PASS"
    else
        RESULTS[$i]="FAIL"
        FAILED=1
    fi
    echo "  ${DISTROS[$i]}: ${RESULTS[$i]}"
done

echo ""
echo "=== Results ==="
for i in "${!DISTROS[@]}"; do
    printf "  %-15s %s\n" "${DISTROS[$i]}" "${RESULTS[$i]}"
    if [[ "${RESULTS[$i]}" == "FAIL" ]]; then
        echo "    last log lines:"
        tail -5 "$LOG_DIR/${DISTROS[$i]}-${COMMAND}-latest.log" 2>/dev/null | sed 's/^/    /'
    fi
done

exit $FAILED
