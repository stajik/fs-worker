#!/usr/bin/env bash
# =============================================================================
# vm-stop.sh — Gracefully stop the worker service and/or the Multipass VM
#
# Usage:
#   ./scripts/vm-stop.sh [--service-only] [--suspend]
#
#   --service-only   Stop the worker process/service but leave the VM running
#   --suspend        Suspend the VM instead of shutting it down (faster resume)
# =============================================================================

set -euo pipefail

VM_NAME="zfs-dev"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[vm-stop]${NC} $*"; }
ok()   { echo -e "${GREEN}[vm-stop]${NC} $*"; }
warn() { echo -e "${YELLOW}[vm-stop]${NC} $*"; }
die()  { echo -e "${RED}[vm-stop] ERROR:${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
SERVICE_ONLY=0
SUSPEND=0
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

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
command -v multipass &>/dev/null || die "multipass is not installed or not in PATH."

VM_STATE=$(multipass list --format csv 2>/dev/null | grep "^${VM_NAME}," | cut -d',' -f2 || true)

if [[ -z "$VM_STATE" ]]; then
    warn "VM '${VM_NAME}' does not exist — nothing to stop."
    exit 0
fi

if [[ "$VM_STATE" != "Running" ]]; then
    warn "VM '${VM_NAME}' is already stopped (state: ${VM_STATE})."
    exit 0
fi

# ---------------------------------------------------------------------------
# Step 1 — Stop the worker process / service
# ---------------------------------------------------------------------------
log "Stopping worker process/service inside VM ..."

multipass exec "$VM_NAME" -- bash -c "
    set -euo pipefail

    STOPPED=0

    # Try the systemd service first
    if sudo systemctl is-active --quiet worker.service 2>/dev/null; then
        echo 'Stopping worker.service via systemctl ...'
        sudo systemctl stop worker.service
        echo 'worker.service stopped.'
        STOPPED=1
    fi

    # Also kill any orphaned foreground worker processes
    if pgrep -x worker &>/dev/null; then
        echo 'Killing foreground worker process(es) ...'
        pkill -TERM -x worker 2>/dev/null || true
        # Give it a moment to exit cleanly
        sleep 2
        # Force-kill if still running
        if pgrep -x worker &>/dev/null; then
            echo 'Process did not exit — sending SIGKILL ...'
            pkill -KILL -x worker 2>/dev/null || true
        fi
        echo 'Worker process stopped.'
        STOPPED=1
    fi

    if [[ \$STOPPED -eq 0 ]]; then
        echo 'No running worker process or service found.'
    fi
" || warn "Could not cleanly stop worker process (VM may have already been partially shut down)."

ok "Worker stopped."

# ---------------------------------------------------------------------------
# Stop any active port-forward tunnel on the host
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# Step 2 — Export ZFS pool before VM shutdown (data safety)
# ---------------------------------------------------------------------------
if [[ $SERVICE_ONLY -eq 0 ]]; then
    log "Exporting ZFS test pool before shutdown ..."

    multipass exec "$VM_NAME" -- sudo bash -c "
        if zpool list testpool &>/dev/null; then
            zpool export testpool
            echo 'testpool exported.'
        else
            echo 'testpool not imported — skipping export.'
        fi
    " || warn "Could not export ZFS pool (may not be imported)."
fi

# ---------------------------------------------------------------------------
# Step 3 — Stop or suspend the VM
# ---------------------------------------------------------------------------
if [[ $SERVICE_ONLY -eq 1 ]]; then
    ok "VM '${VM_NAME}' is still running (--service-only was passed)."
    ok "  Run ./scripts/vm-run.sh to start the worker again."
    exit 0
fi

if [[ $SUSPEND -eq 1 ]]; then
    log "Suspending VM '${VM_NAME}' ..."
    multipass suspend "$VM_NAME"
    ok "VM '${VM_NAME}' suspended."
    ok "  Resume with: multipass start ${VM_NAME}"
else
    log "Shutting down VM '${VM_NAME}' ..."
    multipass stop "$VM_NAME"
    ok "VM '${VM_NAME}' stopped."
    ok "  Start again with: multipass start ${VM_NAME}"
    ok "  Or run the full workflow with: ./scripts/vm-run.sh --rebuild"
fi
