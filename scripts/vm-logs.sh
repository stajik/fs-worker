#!/usr/bin/env bash
# =============================================================================
# vm-logs.sh — Tail the worker service logs inside the Multipass VM
#
# Usage:
#   ./scripts/vm-logs.sh [--lines <n>] [--no-follow] [--system]
#
#   --lines <n>   Number of historical lines to show (default: 50)
#   --no-follow   Print logs and exit instead of following
#   --system      Show system journal for the worker.service unit only
#                 (default: follow the raw process stdout when run in
#                  foreground, or journald when run as a service)
# =============================================================================

set -euo pipefail

VM_NAME="zfs-dev"
LINES=50
FOLLOW=1
SYSTEM=0

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[vm-logs]${NC} $*"; }
ok()   { echo -e "${GREEN}[vm-logs]${NC} $*"; }
warn() { echo -e "${YELLOW}[vm-logs]${NC} $*"; }
die()  { echo -e "${RED}[vm-logs] ERROR:${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --lines)
            [[ -n "${2:-}" ]] || die "--lines requires an argument."
            LINES="$2"
            shift 2
            ;;
        --no-follow) FOLLOW=0; shift ;;
        --system)    SYSTEM=1; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
command -v multipass &>/dev/null || die "multipass is not installed or not in PATH."

VM_STATE=$(multipass list --format csv 2>/dev/null | grep "^${VM_NAME}," | cut -d',' -f2 || true)
[[ -z "$VM_STATE" ]]           && die "VM '${VM_NAME}' does not exist. Run ./scripts/vm-setup.sh first."
[[ "$VM_STATE" != "Running" ]] && die "VM '${VM_NAME}' is not running. Start it with: multipass start ${VM_NAME}"

# ---------------------------------------------------------------------------
# Decide whether the worker is running as a systemd service or not
# ---------------------------------------------------------------------------
IS_SERVICE=0
if multipass exec "$VM_NAME" -- sudo systemctl is-active --quiet worker.service 2>/dev/null; then
    IS_SERVICE=1
fi

if [[ $SYSTEM -eq 1 ]] || [[ $IS_SERVICE -eq 1 ]]; then
    # -------------------------------------------------------------------------
    # journald path — worker is managed by systemd
    # -------------------------------------------------------------------------
    if [[ $IS_SERVICE -eq 1 ]]; then
        log "worker.service is active — reading from journald."
    else
        log "Reading from journald (--system flag set)."
    fi

    JOURNALCTL_FLAGS="-u worker.service -n ${LINES} --no-pager --output=short-precise"
    if [[ $FOLLOW -eq 1 ]]; then
        JOURNALCTL_FLAGS="${JOURNALCTL_FLAGS} -f"
        log "Following logs (Ctrl-C to stop) ..."
        echo ""
    fi

    multipass exec "$VM_NAME" -- sudo journalctl ${JOURNALCTL_FLAGS}

else
    # -------------------------------------------------------------------------
    # Foreground path — look for a running worker process and attach to its
    # output via /proc/<pid>/fd/1, or fall back to journald anyway.
    # -------------------------------------------------------------------------
    WORKER_PID=$(multipass exec "$VM_NAME" -- bash -c "
        pgrep -x worker 2>/dev/null | head -1 || true
    ")

    if [[ -z "$WORKER_PID" ]]; then
        warn "No running worker process found, and worker.service is not active."
        warn "Start the worker with:"
        warn "  ./scripts/vm-run.sh           (foreground)"
        warn "  ./scripts/vm-run.sh --detach  (background service)"
        exit 1
    fi

    log "Found worker process PID ${WORKER_PID}."

    # Check if the process has a log file redirected
    LOG_FILE=$(multipass exec "$VM_NAME" -- bash -c "
        # Check if stdout is redirected to a file
        readlink /proc/${WORKER_PID}/fd/1 2>/dev/null || true
    ")

    if [[ -n "$LOG_FILE" ]] && [[ "$LOG_FILE" != /dev/pts/* ]] && [[ "$LOG_FILE" != pipe:* ]]; then
        # Output is going to a file — tail it
        log "Worker stdout → ${LOG_FILE}"
        if [[ $FOLLOW -eq 1 ]]; then
            log "Following log file (Ctrl-C to stop) ..."
            echo ""
            multipass exec "$VM_NAME" -- tail -n "$LINES" -f "$LOG_FILE"
        else
            multipass exec "$VM_NAME" -- tail -n "$LINES" "$LOG_FILE"
        fi
    else
        # Output is a pipe or PTY — fall back to journald which captures it
        # when run under systemd, or show a helpful message otherwise.
        log "Worker stdout is a pipe/PTY (likely running in an interactive terminal)."
        log "Falling back to journald for recent log entries ..."
        echo ""

        JOURNALCTL_FLAGS="-u worker.service -n ${LINES} --no-pager --output=short-precise"
        if [[ $FOLLOW -eq 1 ]]; then
            JOURNALCTL_FLAGS="${JOURNALCTL_FLAGS} -f"
            log "Following journald (Ctrl-C to stop) ..."
            echo ""
        fi

        # journald may have nothing if the worker was started manually —
        # show a fallback message if that's the case.
        LOG_OUTPUT=$(multipass exec "$VM_NAME" -- sudo journalctl ${JOURNALCTL_FLAGS} 2>&1 || true)

        if echo "$LOG_OUTPUT" | grep -q "No entries"; then
            warn "journald has no entries for worker.service."
            warn "If you started the worker with ./scripts/vm-run.sh (foreground),"
            warn "the logs are in that terminal session."
            warn ""
            warn "To capture logs persistently, use:"
            warn "  ./scripts/vm-run.sh --detach    (runs as a systemd service)"
        else
            echo "$LOG_OUTPUT"
        fi
    fi
fi
