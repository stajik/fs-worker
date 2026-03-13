#!/usr/bin/env bash
# =============================================================================
# vm-build.sh — Build the worker binary inside the Multipass VM
#
# Usage:
#   ./scripts/vm-build.sh [--release] [--clean]
#
#   --release   Build in release mode (default: debug)
#   --clean     Run `cargo clean` before building
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_NAME="zfs-dev"
VM_MOUNT_PATH="/home/ubuntu/worker"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[vm-build]${NC} $*"; }
ok()   { echo -e "${GREEN}[vm-build]${NC} $*"; }
warn() { echo -e "${YELLOW}[vm-build]${NC} $*"; }
die()  { echo -e "${RED}[vm-build] ERROR:${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
RELEASE=0
CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --release) RELEASE=1 ;;
        --clean)   CLEAN=1 ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
command -v multipass &>/dev/null || die "multipass is not installed or not in PATH."

VM_STATE=$(multipass list --format csv 2>/dev/null | grep "^${VM_NAME}," | cut -d',' -f2 || true)
[[ -z "$VM_STATE" ]]   && die "VM '${VM_NAME}' does not exist. Run ./scripts/vm-setup.sh first."
[[ "$VM_STATE" != "Running" ]] && die "VM '${VM_NAME}' is not running. Start it with: multipass start ${VM_NAME}"

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

if [[ $CLEAN -eq 1 ]]; then
    warn "Running cargo clean ..."
    multipass exec "$VM_NAME" -- bash -c "
        source \"\$HOME/.cargo/env\"
        cargo clean --manifest-path ${VM_MOUNT_PATH}/Cargo.toml
    "
fi

multipass exec "$VM_NAME" -- bash -c "
    set -euo pipefail
    source \"\$HOME/.cargo/env\"

    echo '--- Rust version ---'
    rustc --version
    cargo --version

    echo ''
    echo '--- Building worker ---'
    cargo build ${CARGO_FLAGS} --manifest-path ${VM_MOUNT_PATH}/Cargo.toml 2>&1
"

if [[ $RELEASE -eq 1 ]]; then
    BINARY="${VM_MOUNT_PATH}/target/release/worker"
else
    BINARY="${VM_MOUNT_PATH}/target/debug/worker"
fi

ok "Build complete → ${BINARY} (inside VM)"
