#!/usr/bin/env bash
# =============================================================================
# vm-run.sh — Start the worker gRPC service inside the Multipass VM
#
# Usage:
#   ./scripts/vm-run.sh [--release] [--rebuild] [--detach]
#
#   --release   Run the release binary (default: debug)
#   --rebuild   Run vm-build.sh before starting
#   --detach    Run as a background systemd service instead of foreground
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_NAME="zfs-dev"
VM_MOUNT_PATH="/home/ubuntu/worker"
GRPC_PORT=50051

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[vm-run]${NC} $*"; }
ok()   { echo -e "${GREEN}[vm-run]${NC} $*"; }
warn() { echo -e "${YELLOW}[vm-run]${NC} $*"; }
die()  { echo -e "${RED}[vm-run] ERROR:${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
RELEASE=0
REBUILD=0
DETACH=0
for arg in "$@"; do
    case "$arg" in
        --release) RELEASE=1 ;;
        --rebuild) REBUILD=1 ;;
        --detach)  DETACH=1  ;;
        *) die "Unknown argument: $arg" ;;
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
# Optionally rebuild first
# ---------------------------------------------------------------------------
if [[ $REBUILD -eq 1 ]]; then
    log "Rebuilding before starting ..."
    REBUILD_FLAGS=""
    [[ $RELEASE -eq 1 ]] && REBUILD_FLAGS="--release"
    "$SCRIPT_DIR/vm-build.sh" $REBUILD_FLAGS
fi

# ---------------------------------------------------------------------------
# Determine binary path
# ---------------------------------------------------------------------------
if [[ $RELEASE -eq 1 ]]; then
    BINARY="${VM_MOUNT_PATH}/target/release/worker"
    PROFILE="release"
else
    BINARY="${VM_MOUNT_PATH}/target/debug/worker"
    PROFILE="debug"
fi

# Verify the binary exists in the VM
multipass exec "$VM_NAME" -- bash -c "
    test -f '${BINARY}' || {
        echo 'Binary not found: ${BINARY}'
        echo 'Run ./scripts/vm-build.sh first, or pass --rebuild.'
        exit 1
    }
" || die "Binary '${BINARY}' not found inside VM."

# ---------------------------------------------------------------------------
# Ensure ZFS test pool is imported
# ---------------------------------------------------------------------------
log "Ensuring ZFS test pool is available ..."
multipass exec "$VM_NAME" -- sudo bash -c "
    if ! zpool list testpool &>/dev/null; then
        echo 'Importing testpool ...'
        systemctl start zfs-loopback-pool.service || true
        sleep 1
        zpool list testpool 2>/dev/null && echo 'Pool imported.' || echo 'WARNING: testpool not available.'
    else
        echo 'testpool already imported.'
    fi
"

# ---------------------------------------------------------------------------
# Detach mode — manage via systemd worker.service
# ---------------------------------------------------------------------------
if [[ $DETACH -eq 1 ]]; then
    log "Starting worker as a background systemd service ..."

    multipass exec "$VM_NAME" -- sudo bash -c "
        # Patch the service unit to point at the correct binary profile
        sed -i 's|ExecStart=.*|ExecStart=${BINARY}|' /etc/systemd/system/worker.service
        systemctl daemon-reload
        systemctl restart worker.service
        sleep 2
        systemctl status worker.service --no-pager
    "

    VM_IP=$(multipass info "$VM_NAME" | awk '/IPv4/ {print $2}')
    ok "Worker service started in background."
    ok "  Binary  : ${BINARY} (${PROFILE})"
    ok "  gRPC    : ${VM_IP}:${GRPC_PORT}"
    ok ""
    ok "  Useful commands:"
    ok "    ./scripts/vm-logs.sh              # tail service logs"
    ok "    ./scripts/vm-port-forward.sh      # forward to localhost:${GRPC_PORT}"
    ok "    multipass exec ${VM_NAME} -- sudo systemctl stop worker.service"
    exit 0
fi

# ---------------------------------------------------------------------------
# Foreground mode — run directly, stream output to this terminal
# ---------------------------------------------------------------------------
VM_IP=$(multipass info "$VM_NAME" | awk '/IPv4/ {print $2}')

log "Starting worker in foreground (${PROFILE} build) ..."
log "  gRPC endpoint inside VM : [::1]:${GRPC_PORT}"
log "  VM IP                   : ${VM_IP}"
log "  Press Ctrl-C to stop."
echo ""

# Kill any existing foreground worker process first
multipass exec "$VM_NAME" -- bash -c "
    pkill -x worker 2>/dev/null && echo 'Stopped previous worker process.' || true
" || true

multipass exec "$VM_NAME" -- bash -c "
    export RUST_LOG=\${RUST_LOG:-info}
    exec '${BINARY}'
"
