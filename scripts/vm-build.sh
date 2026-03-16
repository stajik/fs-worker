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
#   --release   Build in release mode (default: debug)
#   --clean     Run `cargo clean` before building
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
    warn "Running cargo clean ..."
    remote_cargo "cargo clean --manifest-path '${WORK_DIR}/Cargo.toml'"
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
CARGO_FLAGS=""
if [[ $RELEASE -eq 1 ]]; then
    CARGO_FLAGS="--release"
    log "Building in release mode ..."
else
    log "Building in debug mode ..."
fi

remote_cargo "
    set -euo pipefail

    echo '--- Rust version ---'
    rustc --version
    cargo --version

    echo ''
    echo '--- Building fs-worker ---'
    cargo build ${CARGO_FLAGS} --manifest-path '${WORK_DIR}/Cargo.toml' 2>&1
"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
if [[ $RELEASE -eq 1 ]]; then
    BINARY="${WORK_DIR}/target/release/fs-worker"
else
    BINARY="${WORK_DIR}/target/debug/fs-worker"
fi

ok "Build complete → ${BINARY} (on target)"
