#!/usr/bin/env bash
# =============================================================================
# vm-logs.sh — Tail the fs-worker service logs on the target
#
# Local mode  (default):  reads logs from the Multipass VM
# Remote mode (--remote): reads logs from the bare-metal SSH host in .env
#
# Usage:
#   ./scripts/vm-logs.sh [--remote] [--lines <n>] [--no-follow] [--system]
#
#   --remote      Target the SSH bare-metal host defined in .env
#   --lines <n>   Number of historical lines to show (default: 50)
#   --no-follow   Print logs and exit instead of following
#   --system      Force journald output even if the process is running in
#                 the foreground (default: auto-detect)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PREFIX="[vm-logs]"
source "${SCRIPT_DIR}/lib.sh"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
LINES=50
FOLLOW=1
SYSTEM=0

parse_mode_flag "$@"
set -- "${FILTERED_ARGS[@]}"

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
# Validate mode and connectivity
# ---------------------------------------------------------------------------
validate_mode
remote_check_reachable

print_mode_banner
echo ""

# ---------------------------------------------------------------------------
# Decide whether fs-worker is managed by systemd or running in the foreground
# ---------------------------------------------------------------------------
IS_SERVICE=0
if remote_service_active "fs-worker.service" 2>/dev/null; then
    IS_SERVICE=1
fi

if [[ $SYSTEM -eq 1 ]] || [[ $IS_SERVICE -eq 1 ]]; then
    # -------------------------------------------------------------------------
    # journald path — fs-worker is managed by systemd
    # -------------------------------------------------------------------------
    if [[ $IS_SERVICE -eq 1 ]]; then
        log "fs-worker.service is active — reading from journald."
    else
        log "Reading from journald (--system flag set)."
    fi

    JOURNALCTL_FLAGS="-u fs-worker.service -n ${LINES} --no-pager --output=short-precise"
    if [[ $FOLLOW -eq 1 ]]; then
        JOURNALCTL_FLAGS="${JOURNALCTL_FLAGS} -f"
        log "Following logs (Ctrl-C to stop) ..."
        echo ""
    fi

    remote_exec_sudo "journalctl ${JOURNALCTL_FLAGS}"

else
    # -------------------------------------------------------------------------
    # Foreground path — look for a running fs-worker process
    # -------------------------------------------------------------------------
    WORKER_PID=$(remote_exec "pgrep -x fs-worker 2>/dev/null | head -1 || true")

    if [[ -z "$WORKER_PID" ]]; then
        warn "No running fs-worker process found, and fs-worker.service is not active."
        warn "Start the worker with:"
        warn "  ./scripts/vm-run.sh           (foreground)"
        warn "  ./scripts/vm-run.sh --detach  (background service)"
        exit 1
    fi

    log "Found fs-worker process PID ${WORKER_PID}."

    # Check if stdout is redirected to a file
    LOG_FILE=$(remote_exec "readlink /proc/${WORKER_PID}/fd/1 2>/dev/null || true")

    if [[ -n "$LOG_FILE" ]] && [[ "$LOG_FILE" != /dev/pts/* ]] && [[ "$LOG_FILE" != pipe:* ]]; then
        log "Worker stdout → ${LOG_FILE}"
        if [[ $FOLLOW -eq 1 ]]; then
            log "Following log file (Ctrl-C to stop) ..."
            echo ""
            remote_exec "tail -n ${LINES} -f '${LOG_FILE}'"
        else
            remote_exec "tail -n ${LINES} '${LOG_FILE}'"
        fi
    else
        # Stdout is a pipe/PTY — fall back to journald
        log "Worker stdout is a pipe/PTY. Falling back to journald ..."
        echo ""

        JOURNALCTL_FLAGS="-u fs-worker.service -n ${LINES} --no-pager --output=short-precise"
        if [[ $FOLLOW -eq 1 ]]; then
            JOURNALCTL_FLAGS="${JOURNALCTL_FLAGS} -f"
            log "Following journald (Ctrl-C to stop) ..."
            echo ""
        fi

        LOG_OUTPUT=$(remote_exec_sudo "journalctl ${JOURNALCTL_FLAGS}" 2>&1 || true)

        if echo "$LOG_OUTPUT" | grep -q "No entries"; then
            warn "journald has no entries for fs-worker.service."
            warn "If the worker was started with ./scripts/vm-run.sh (foreground),"
            warn "the logs are in that terminal session."
            warn ""
            warn "To capture logs persistently, use:"
            warn "  ./scripts/vm-run.sh --detach    (runs as a systemd service)"
        else
            echo "$LOG_OUTPUT"
        fi
    fi
fi
