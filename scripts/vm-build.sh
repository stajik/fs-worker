#!/usr/bin/env bash
# =============================================================================
# vm-build.sh — Build the fs-worker binary on the target
#
# Local mode  (default):  builds inside the Multipass VM
# Remote mode (--remote): builds on the bare-metal SSH host defined in .env
#
# Usage:
#   ./scripts/vm-build.sh [--remote] [--release] [--clean]
#
#   --remote    Target the SSH bare-metal host defined in .env
#   --release   Build with optimisations (default: debug, with -N -l)
#   --clean     Remove the previously built binary before building
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PREFIX="[vm-build]"
source "${SCRIPT_DIR}/lib.sh"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
RELEASE=0
CLEAN=0

parse_mode_flag "$@"
set -- "${FILTERED_ARGS[@]}"

for arg in "$@"; do
    case "$arg" in
        --release) RELEASE=1 ;;
        --clean)   CLEAN=1   ;;
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
# In remote mode, sync the source to the host before building
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "remote" ]]; then
    log "Syncing source to ${REMOTE_HOST}:${WORK_DIR} ..."
    remote_copy "${PROJECT_DIR}/" "${WORK_DIR}/"
    ok "Source synced."
fi

# ---------------------------------------------------------------------------
# Optional clean
# ---------------------------------------------------------------------------
if [[ $CLEAN -eq 1 ]]; then
    warn "Removing previous binary ..."
    remote_go "rm -f '${WORK_DIR}/fs-worker'"
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
BINARY="${WORK_DIR}/fs-worker"

if [[ $RELEASE -eq 1 ]]; then
    log "Building in release mode ..."
    remote_exec_as_worker "
        set -euo pipefail
        export PATH=\$PATH:/usr/local/go/bin
        echo '--- Go version ---'
        go version
        echo ''
        echo '--- Building fs-worker (release) ---'
        cd '${WORK_DIR}'
        go build -o fs-worker . 2>&1
    "
else
    log "Building in debug mode ..."
    remote_exec_as_worker "
        set -euo pipefail
        export PATH=\$PATH:/usr/local/go/bin
        echo '--- Go version ---'
        go version
        echo ''
        echo '--- Building fs-worker (debug) ---'
        cd '${WORK_DIR}'
        go build -gcflags='all=-N -l' -o fs-worker . 2>&1
    "
fi

ok "Build complete → ${BINARY} (on target)"
