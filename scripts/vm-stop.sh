#!/usr/bin/env bash
# =============================================================================
# vm-stop.sh — Gracefully stop the fs-worker service and/or the target
#
# Local mode  (default):  stops the Multipass VM
# Remote mode (--remote): stops the service on the bare-metal SSH host in .env
#
# Usage:
#   ./scripts/vm-stop.sh [--remote] [--service-only] [--suspend]
#
#   --remote        Target the SSH bare-metal host defined in .env
#   --service-only  Stop the worker process/service but leave the host running
#   --suspend       (local only) Suspend the VM instead of shutting it down
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PREFIX="[vm-stop]"
source "${SCRIPT_DIR}/lib.sh"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
SERVICE_ONLY=0
SUSPEND=0

parse_mode_flag "$@"
set -- "${FILTERED_ARGS[@]}"

for arg in "$@"; do
    case "$arg" in
        --service-only) SERVICE_ONLY=1 ;;
        --suspend)      SUSPEND=1      ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

if [[ $SERVICE_ONLY -eq 1 && $SUSPEND -eq 1 ]]; then
    die "--service-only and --suspend are mutually exclusive."
fi

if [[ "${MODE}" == "remote" && $SUSPEND -eq 1 ]]; then
    die "--suspend is only supported in local (Multipass) mode."
fi

# ---------------------------------------------------------------------------
# Validate mode
# ---------------------------------------------------------------------------
validate_mode

print_mode_banner
echo ""

# ---------------------------------------------------------------------------
# Connectivity check — skip if the VM/host might already be down
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "local" ]]; then
    VM_STATE=$(multipass list --format csv 2>/dev/null \
        | grep "^${VM_NAME}," | cut -d',' -f2 || true)

    if [[ -z "$VM_STATE" ]]; then
        warn "VM '${VM_NAME}' does not exist — nothing to stop."
        exit 0
    fi

    if [[ "$VM_STATE" != "Running" ]]; then
        warn "VM '${VM_NAME}' is already stopped (state: ${VM_STATE})."
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Step 1 — Stop the fs-worker process / service
# ---------------------------------------------------------------------------
log "Stopping fs-worker process/service on target ..."

remote_exec "
    set -euo pipefail
    STOPPED=0

    # Try the systemd service first
    if sudo systemctl is-active --quiet fs-worker.service 2>/dev/null; then
        echo 'Stopping fs-worker.service via systemctl ...'
        sudo systemctl stop fs-worker.service
        echo 'fs-worker.service stopped.'
        STOPPED=1
    fi

    # Kill any orphaned foreground fs-worker processes
    if pgrep -x fs-worker &>/dev/null; then
        echo 'Killing foreground fs-worker process(es) ...'
        pkill -TERM -x fs-worker 2>/dev/null || true
        sleep 2
        if pgrep -x fs-worker &>/dev/null; then
            echo 'Process did not exit — sending SIGKILL ...'
            pkill -KILL -x fs-worker 2>/dev/null || true
        fi
        echo 'fs-worker process stopped.'
        STOPPED=1
    fi

    if [[ \$STOPPED -eq 0 ]]; then
        echo 'No running fs-worker process or service found.'
    fi
" || warn "Could not cleanly stop fs-worker (target may have already been partially shut down)."

ok "fs-worker stopped."

# ---------------------------------------------------------------------------
# Stop any active port-forward tunnel on the host Mac
# ---------------------------------------------------------------------------
PID_FILE="${SCRIPT_DIR}/.vm-tunnel.pid"

if [[ -f "$PID_FILE" ]]; then
    TUNNEL_PID=$(cat "$PID_FILE")
    if kill -0 "$TUNNEL_PID" 2>/dev/null; then
        log "Stopping port-forward tunnel (PID ${TUNNEL_PID}) ..."
        kill "$TUNNEL_PID" 2>/dev/null || true
        ok "Tunnel stopped."
    fi
    rm -f "$PID_FILE"
fi

# ---------------------------------------------------------------------------
# Step 2 — Export ZFS pool before shutdown (data safety)
# ---------------------------------------------------------------------------
if [[ $SERVICE_ONLY -eq 0 ]]; then
    log "Exporting ZFS pool '${ZFS_POOL}' before shutdown ..."
    export_pool "${ZFS_POOL}"
fi

# ---------------------------------------------------------------------------
# Step 3 — Stop or suspend the target
# ---------------------------------------------------------------------------
if [[ $SERVICE_ONLY -eq 1 ]]; then
    ok "Target is still running (--service-only was passed)."
    ok "  Run ./scripts/vm-run.sh to start the worker again."
    exit 0
fi

if [[ "${MODE}" == "remote" ]]; then
    # In remote mode there is no VM lifecycle to manage — the bare-metal host
    # stays up. We have already stopped the service above.
    ok "Remote host '${REMOTE_HOST}' remains running (no VM to shut down)."
    ok "  The fs-worker service has been stopped."
    ok "  To restart it: ./scripts/vm-run.sh --remote --detach"
    exit 0
fi

# Local (Multipass) mode — stop or suspend the VM
if [[ $SUSPEND -eq 1 ]]; then
    log "Suspending VM '${VM_NAME}' ..."
    multipass suspend "${VM_NAME}"
    ok "VM '${VM_NAME}' suspended."
    ok "  Resume with: multipass start ${VM_NAME}"
else
    log "Shutting down VM '${VM_NAME}' ..."
    multipass stop "${VM_NAME}"
    ok "VM '${VM_NAME}' stopped."
    ok "  Start again with:  multipass start ${VM_NAME}"
    ok "  Full restart with: ./scripts/vm-run.sh --rebuild"
fi
