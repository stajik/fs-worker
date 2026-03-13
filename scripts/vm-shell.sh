#!/usr/bin/env bash
# =============================================================================
# vm-shell.sh — Open an interactive shell inside the Multipass VM
#
# Usage:
#   ./scripts/vm-shell.sh [--root]
#
#   --root   Open a root shell instead of the default ubuntu user shell
# =============================================================================

set -euo pipefail

VM_NAME="zfs-dev"
AS_ROOT=0

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[vm-shell]${NC} $*"; }
ok()   { echo -e "${GREEN}[vm-shell]${NC} $*"; }
warn() { echo -e "${YELLOW}[vm-shell]${NC} $*"; }
die()  { echo -e "${RED}[vm-shell] ERROR:${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --root) AS_ROOT=1 ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
command -v multipass &>/dev/null || die "multipass is not installed or not in PATH."

VM_STATE=$(multipass list --format csv 2>/dev/null | grep "^${VM_NAME}," | cut -d',' -f2 || true)

if [[ -z "$VM_STATE" ]]; then
    die "VM '${VM_NAME}' does not exist. Run ./scripts/vm-setup.sh first."
fi

if [[ "$VM_STATE" != "Running" ]]; then
    warn "VM '${VM_NAME}' is not running. Starting it now ..."
    multipass start "$VM_NAME"
    ok "VM started."
fi

# ---------------------------------------------------------------------------
# Print a short status summary before dropping into the shell
# ---------------------------------------------------------------------------
VM_IP=$(multipass info "$VM_NAME" 2>/dev/null | awk '/IPv4/ {print $2}' | head -1)

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  VM   : ${VM_NAME}  (Ubuntu 24.04)                  ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  IP   : ${VM_IP:-unknown}                                ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Work : /home/ubuntu/worker                       ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Pool : testpool                                   ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Useful commands once inside:"
echo -e "    ${GREEN}zpool status${NC}                    # ZFS pool health"
echo -e "    ${GREEN}zfs list${NC}                        # list all datasets"
echo -e "    ${GREEN}cd ~/worker && cargo build${NC}      # build the worker"
echo -e "    ${GREEN}sudo systemctl status worker${NC}    # service status"
echo -e "    ${GREEN}sudo journalctl -fu worker${NC}      # follow service logs"
echo ""

# ---------------------------------------------------------------------------
# Open the shell
# ---------------------------------------------------------------------------
if [[ $AS_ROOT -eq 1 ]]; then
    log "Opening root shell in '${VM_NAME}' ..."
    multipass exec "$VM_NAME" -- sudo -i bash
else
    log "Opening shell in '${VM_NAME}' as ubuntu ..."
    multipass shell "$VM_NAME"
fi
