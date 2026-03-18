#!/usr/bin/env bash
# =============================================================================
# vm-shell.sh — Open an interactive shell on the target
#
# Local mode  (default):  opens a shell inside the Multipass VM
# Remote mode (--remote): opens an SSH shell on the bare-metal host in .env
#
# Usage:
#   ./scripts/vm-shell.sh [--remote] [--root]
#
#   --remote   Target the SSH bare-metal host defined in .env
#   --root     Open a root shell instead of the default user shell
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PREFIX="[vm-shell]"
source "${SCRIPT_DIR}/lib.sh"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
AS_ROOT=0

parse_mode_flag "$@"
set -- "${FILTERED_ARGS[@]}"

for arg in "$@"; do
    case "$arg" in
        --root) AS_ROOT=1 ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate mode — start the VM if needed (local mode only)
# ---------------------------------------------------------------------------
validate_mode

if [[ "${MODE}" == "local" ]]; then
    VM_STATE=$(multipass list --format csv 2>/dev/null \
        | grep "^${VM_NAME}," | cut -d',' -f2 || true)

    if [[ -z "$VM_STATE" ]]; then
        die "VM '${VM_NAME}' does not exist. Run ./scripts/vm-setup.sh first."
    fi

    if [[ "$VM_STATE" != "Running" ]]; then
        warn "VM '${VM_NAME}' is not running. Starting it now ..."
        multipass start "$VM_NAME"
        ok "VM started."
    fi
fi

remote_check_reachable

WORK_DIR="$(remote_work_dir)"
TARGET_IP="$(remote_ip)"

# ---------------------------------------------------------------------------
# Print a status summary before dropping into the shell
# ---------------------------------------------------------------------------
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
if [[ "${MODE}" == "remote" ]]; then
echo -e "${CYAN}║${NC}  Mode : remote (SSH bare-metal)                       ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Host : ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}$(printf '%*s' $((37 - ${#REMOTE_USER} - ${#REMOTE_HOST} - ${#REMOTE_PORT})) '')${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Key  : ${REMOTE_PEM}$(printf '%*s' $((46 - ${#REMOTE_PEM})) '')${CYAN}║${NC}"
else
echo -e "${CYAN}║${NC}  Mode : local (Multipass)                             ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  VM   : ${VM_NAME}  (${TARGET_IP:-unknown})$(printf '%*s' $((40 - ${#VM_NAME} - ${#TARGET_IP:-7}) ) '')${CYAN}║${NC}"
fi
echo -e "${CYAN}║${NC}  Work : ${WORK_DIR}$(printf '%*s' $((46 - ${#WORK_DIR})) '')${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  Pool : ${ZFS_POOL}$(printf '%*s' $((46 - ${#ZFS_POOL})) '')${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Useful commands once inside:"
echo -e "    ${GREEN}zpool status${NC}                         # ZFS pool health"
echo -e "    ${GREEN}zfs list${NC}                             # list all datasets"
echo -e "    ${GREEN}cd ${WORK_DIR} && go build -o fs-worker .${NC}  # build fs-worker"
echo -e "    ${GREEN}sudo systemctl status fs-worker${NC}      # service status"
echo -e "    ${GREEN}sudo journalctl -fu fs-worker${NC}        # follow service logs"
echo ""

# ---------------------------------------------------------------------------
# Open the shell
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "remote" ]]; then
    SSH_OPTS=(
        -i "${REMOTE_PEM}"
        -p "${REMOTE_PORT}"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
        -o ServerAliveInterval=30
        -o ServerAliveCountMax=3
    )

    if [[ $AS_ROOT -eq 1 ]]; then
        log "Opening root shell on ${REMOTE_HOST} ..."
        ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" -t "sudo -i bash"
    else
        log "Opening shell on ${REMOTE_HOST} as ${REMOTE_USER} ..."
        ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}"
    fi
else
    if [[ $AS_ROOT -eq 1 ]]; then
        log "Opening root shell in VM '${VM_NAME}' ..."
        multipass exec "${VM_NAME}" -- sudo -i bash
    else
        log "Opening shell in VM '${VM_NAME}' as ubuntu ..."
        multipass shell "${VM_NAME}"
    fi
fi
