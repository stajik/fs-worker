#!/usr/bin/env bash
# =============================================================================
# vm-run.sh — Start the fs-worker on the target
#
# Local mode  (default):  runs inside the Multipass VM
# Remote mode (--remote): runs on the bare-metal SSH host defined in .env
#
# Usage:
#   ./scripts/vm-run.sh [--remote] [--release] [--rebuild] [--detach]
#
#   --remote    Target the SSH bare-metal host defined in .env
#   --release   Run the release binary (default: debug)
#   --rebuild   Run vm-build.sh before starting
#   --detach    Run as a background systemd service instead of foreground
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PREFIX="[vm-run]"
source "${SCRIPT_DIR}/lib.sh"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
RELEASE=0
REBUILD=0
DETACH=0

parse_mode_flag "$@"
set -- "${FILTERED_ARGS[@]}"

for arg in "$@"; do
    case "$arg" in
        --release) RELEASE=1 ;;
        --rebuild) REBUILD=1 ;;
        --detach)  DETACH=1  ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate mode and connectivity
# ---------------------------------------------------------------------------
validate_mode
remote_check_reachable

WORK_DIR="$(remote_work_dir)"

print_mode_banner
echo ""

# ---------------------------------------------------------------------------
# Optionally rebuild first
# ---------------------------------------------------------------------------
if [[ $REBUILD -eq 1 ]]; then
    log "Rebuilding before starting ..."
    BUILD_FLAGS=""
    [[ $RELEASE -eq 1 ]] && BUILD_FLAGS="--release"
    [[ "${MODE}" == "remote" ]] && BUILD_FLAGS="--remote ${BUILD_FLAGS}"
    "$SCRIPT_DIR/vm-build.sh" ${BUILD_FLAGS}
fi

# ---------------------------------------------------------------------------
# Determine binary path
# ---------------------------------------------------------------------------
BINARY="${WORK_DIR}/fs-worker"
PROFILE="release"
[[ $RELEASE -eq 0 ]] && PROFILE="debug"

# Verify the binary exists on the target
remote_exec_as_worker "
    test -f '${BINARY}' || {
        echo 'Binary not found: ${BINARY}'
        echo 'Run ./scripts/vm-build.sh first, or pass --rebuild.'
        exit 1
    }
" || die "Binary '${BINARY}' not found on target."

# ---------------------------------------------------------------------------
# Ensure Temporal is reachable from the target
# ---------------------------------------------------------------------------
log "Checking Temporal connectivity ..."
ensure_temporal_reachable

# ---------------------------------------------------------------------------
# Ensure ZFS pool is imported
# ---------------------------------------------------------------------------
log "Ensuring ZFS pool '${ZFS_POOL}' is available ..."
ensure_pool_imported "${ZFS_POOL}"

# ---------------------------------------------------------------------------
# Detach mode — manage via systemd fs-worker.service
# ---------------------------------------------------------------------------
if [[ $DETACH -eq 1 ]]; then
    log "Starting fs-worker as a background systemd service ..."

    remote_exec_sudo "
        sed -i 's|ExecStart=.*|ExecStart=${BINARY}|' /etc/systemd/system/fs-worker.service
        systemctl daemon-reload
        systemctl restart fs-worker.service
        sleep 2
        systemctl status fs-worker.service --no-pager
    "

    TARGET_IP="$(remote_ip)"
    ok "fs-worker service started in background."
    ok "  Binary  : ${BINARY} (${PROFILE})"
    ok "  Host    : ${TARGET_IP}"
    ok ""
    ok "  Useful commands:"
    ok "    ./scripts/vm-logs.sh              # tail service logs"
    ok "    ./scripts/vm-port-forward.sh      # forward Temporal port to localhost"
    if [[ "${MODE}" == "remote" ]]; then
        ok "    ssh -i ${REMOTE_PEM} ${REMOTE_USER}@${REMOTE_HOST} 'sudo systemctl stop fs-worker.service'"
    else
        ok "    multipass exec ${VM_NAME} -- sudo systemctl stop fs-worker.service"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Foreground mode — run directly, stream output to this terminal
# ---------------------------------------------------------------------------
TARGET_IP="$(remote_ip)"

log "Starting fs-worker in foreground (${PROFILE} build) ..."
log "  Host        : ${TARGET_IP}"
log "  Press Ctrl-C to stop."
echo ""

# Kill any existing foreground fs-worker process
remote_exec_as_worker "pkill -x fs-worker 2>/dev/null && echo 'Stopped previous fs-worker process.' || true" || true

remote_exec_as_worker "
    export ZFS_POOL='${ZFS_POOL}'
    exec '${BINARY}'
"
