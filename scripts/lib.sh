#!/usr/bin/env bash
# =============================================================================
# lib.sh — Shared library sourced by all fs-worker scripts
#
# Provides:
#   - Mode detection: "local" (Multipass) vs "remote" (SSH bare-metal)
#   - .env loading from the project root
#   - Unified transport functions that work in both modes:
#       remote_exec         <cmd>   — run as the remote user
#       remote_exec_sudo    <cmd>   — run as root
#       remote_ip                   — print the target IP / hostname
#       remote_copy         <src> <dst> — rsync local → remote
#   - Common colour helpers: log / ok / warn / die
#
# Usage (in each script):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/lib.sh"
#
# Mode is selected by:
#   1. Passing --remote anywhere on the command line before sourcing, OR
#   2. The presence of REMOTE_HOST in .env (auto-selects remote mode), OR
#   3. Default: local (Multipass) mode
#
# .env format  (stored at project root, never committed):
#   REMOTE_HOST=1.2.3.4        # IP or hostname of the bare-metal machine
#   REMOTE_USER=ubuntu         # SSH login user
#   REMOTE_PEM=/path/to/key.pem # Path to the PEM private key
#
# Optional .env variables (all have defaults):
#   REMOTE_PORT=22             # SSH port
#   REMOTE_WORK_DIR=/home/ubuntu/fs-worker  # project dir on remote
#   VM_NAME=zfs-dev            # Multipass VM name (local mode only)
#   ZFS_POOL=testpool          # ZFS pool name used by the worker
# =============================================================================

# Guard against double-sourcing
[[ -n "${_FS_WORKER_LIB_LOADED:-}" ]] && return 0
_FS_WORKER_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------

# SCRIPT_DIR must be set by the sourcing script before sourcing lib.sh.
# Fall back to the directory of lib.sh itself if not set.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="${SCRIPT_DIR:-${_LIB_DIR}}"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Prefix is set per-script before sourcing, e.g. LOG_PREFIX="[vm-build]"
# Falls back to "[fs-worker]" if not set.
_log_prefix() { echo "${LOG_PREFIX:-[fs-worker]}"; }

log()  { echo -e "${CYAN}$(_log_prefix)${NC} $*"; }
ok()   { echo -e "${GREEN}$(_log_prefix)${NC} $*"; }
warn() { echo -e "${YELLOW}$(_log_prefix)${NC} $*"; }
die()  { echo -e "${RED}$(_log_prefix) ERROR:${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# .env loading
# ---------------------------------------------------------------------------
ENV_FILE="${PROJECT_DIR}/.env"

load_env() {
    if [[ -f "${ENV_FILE}" ]]; then
        # Export every non-comment, non-blank line.
        # Handles both   KEY=value   and   export KEY=value   forms.
        # Does NOT execute arbitrary code.
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Strip leading whitespace
            line="${line#"${line%%[![:space:]]*}"}"
            # Skip blank lines and comments
            [[ -z "$line" || "$line" == \#* ]] && continue
            # Strip optional leading "export "
            line="${line#export }"
            # Only process lines that look like KEY=...
            if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
                export "${line?}"
            fi
        done < "${ENV_FILE}"
    fi
}

load_env

# ---------------------------------------------------------------------------
# Defaults (can be overridden in .env or environment)
# ---------------------------------------------------------------------------
VM_NAME="${VM_NAME:-zfs-dev}"
VM_MOUNT_PATH="${VM_MOUNT_PATH:-/home/ubuntu/fs-worker}"

REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-ubuntu}"
REMOTE_PEM="${REMOTE_PEM:-}"
REMOTE_PORT="${REMOTE_PORT:-22}"
REMOTE_WORK_DIR="${REMOTE_WORK_DIR:-/home/ubuntu/fs-worker}"

ZFS_POOL="${ZFS_POOL:-testpool}"

# ---------------------------------------------------------------------------
# Mode detection
# ---------------------------------------------------------------------------
# Remote mode is active when:
#   (a) --remote was passed as an argument to the calling script, OR
#   (b) REMOTE_HOST is non-empty (set via .env or environment)
#
# Scripts should call parse_mode_flag "$@" early, which strips --remote from
# the argument list and sets MODE.

MODE="local"  # default

# Check if --remote is present in the raw argument list passed to the script
# that sourced us. We inspect the caller's "$@" only if they call parse_mode_flag.
parse_mode_flag() {
    local new_args=()
    for arg in "$@"; do
        if [[ "$arg" == "--remote" ]]; then
            MODE="remote"
        else
            new_args+=("$arg")
        fi
    done
    # Return the filtered argument list via FILTERED_ARGS
    FILTERED_ARGS=("${new_args[@]}")
}

# Auto-promote to remote mode when REMOTE_HOST is configured in .env, even if
# --remote wasn't passed explicitly.
if [[ -n "${REMOTE_HOST}" && "${MODE}" == "local" ]]; then
    MODE="remote"
fi

# ---------------------------------------------------------------------------
# Mode validation
# ---------------------------------------------------------------------------
validate_mode() {
    if [[ "${MODE}" == "remote" ]]; then
        [[ -n "${REMOTE_HOST}" ]] || die \
            "Remote mode requires REMOTE_HOST. Set it in ${ENV_FILE}."
        [[ -n "${REMOTE_PEM}" ]] || die \
            "Remote mode requires REMOTE_PEM (path to .pem key). Set it in ${ENV_FILE}."
        [[ -f "${REMOTE_PEM}" ]] || die \
            "PEM key file not found: ${REMOTE_PEM}"
        command -v ssh  &>/dev/null || die "ssh is not installed or not in PATH."
        command -v rsync &>/dev/null || die "rsync is not installed or not in PATH."
    else
        command -v multipass &>/dev/null || die \
            "multipass is not installed or not in PATH. Install it or use --remote mode."
    fi
}

# ---------------------------------------------------------------------------
# SSH base options (shared by exec and tunnel functions)
# ---------------------------------------------------------------------------
_ssh_opts() {
    echo -n "-i ${REMOTE_PEM} "
    echo -n "-p ${REMOTE_PORT} "
    echo -n "-o StrictHostKeyChecking=no "
    echo -n "-o UserKnownHostsFile=/dev/null "
    echo -n "-o LogLevel=ERROR "
    echo -n "-o ServerAliveInterval=30 "
    echo -n "-o ServerAliveCountMax=3 "
    echo -n "-o ConnectTimeout=10 "
}

# ---------------------------------------------------------------------------
# Unified transport functions
# ---------------------------------------------------------------------------

# remote_exec <cmd-string>
# Run a bash command on the target (as the remote user).
remote_exec() {
    local cmd="$1"
    if [[ "${MODE}" == "remote" ]]; then
        # shellcheck disable=SC2046
        ssh $(_ssh_opts) "${REMOTE_USER}@${REMOTE_HOST}" "bash -c $(printf '%q' "$cmd")"
    else
        multipass exec "${VM_NAME}" -- bash -c "$cmd"
    fi
}

# remote_exec_sudo <cmd-string>
# Run a bash command on the target as root.
remote_exec_sudo() {
    local cmd="$1"
    if [[ "${MODE}" == "remote" ]]; then
        # shellcheck disable=SC2046
        ssh $(_ssh_opts) "${REMOTE_USER}@${REMOTE_HOST}" "sudo bash -c $(printf '%q' "$cmd")"
    else
        multipass exec "${VM_NAME}" -- sudo bash -c "$cmd"
    fi
}

# remote_ip
# Print the IP address / hostname of the target.
remote_ip() {
    if [[ "${MODE}" == "remote" ]]; then
        echo "${REMOTE_HOST}"
    else
        multipass info "${VM_NAME}" 2>/dev/null | awk '/IPv4/ {print $2}' | head -1
    fi
}

# remote_work_dir
# Print the project directory path on the target.
remote_work_dir() {
    if [[ "${MODE}" == "remote" ]]; then
        echo "${REMOTE_WORK_DIR}"
    else
        echo "${VM_MOUNT_PATH}"
    fi
}

# remote_copy <local-src> <remote-dst>
# Sync a local path to the remote target using rsync over SSH (remote mode)
# or a plain multipass transfer fallback (local mode).
remote_copy() {
    local src="$1"
    local dst="$2"
    if [[ "${MODE}" == "remote" ]]; then
        rsync -az \
            -e "ssh $(_ssh_opts)" \
            "${src}" \
            "${REMOTE_USER}@${REMOTE_HOST}:${dst}"
    else
        # Multipass has no direct rsync; use the shared mount (src is already
        # visible inside the VM via the mount). Emit a no-op notice.
        log "(local mode) Files are shared via Multipass mount — no copy needed."
    fi
}

# remote_check_reachable
# Die with a helpful message if the target cannot be reached.
remote_check_reachable() {
    if [[ "${MODE}" == "remote" ]]; then
        # shellcheck disable=SC2046
        ssh $(_ssh_opts) -o ConnectTimeout=5 \
            "${REMOTE_USER}@${REMOTE_HOST}" "echo ok" &>/dev/null \
            || die "Cannot reach ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}. \
Check REMOTE_HOST, REMOTE_USER, REMOTE_PEM and REMOTE_PORT in ${ENV_FILE}."
    else
        local state
        state=$(multipass list --format csv 2>/dev/null \
            | grep "^${VM_NAME}," | cut -d',' -f2 || true)
        [[ -z "$state" ]] && die \
            "VM '${VM_NAME}' does not exist. Run ./scripts/vm-setup.sh first."
        [[ "$state" != "Running" ]] && die \
            "VM '${VM_NAME}' is not running. Start it with: multipass start ${VM_NAME}"
    fi
}

# ---------------------------------------------------------------------------
# Mode banner (called by scripts that want to show which mode is active)
# ---------------------------------------------------------------------------
print_mode_banner() {
    if [[ "${MODE}" == "remote" ]]; then
        log "Mode     : ${BOLD}remote (SSH bare-metal)${NC}"
        log "Host     : ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}"
        log "PEM      : ${REMOTE_PEM}"
        log "Work dir : ${REMOTE_WORK_DIR}"
    else
        local ip
        ip=$(remote_ip 2>/dev/null || echo "unknown")
        log "Mode     : ${BOLD}local (Multipass)${NC}"
        log "VM       : ${VM_NAME}  (${ip})"
        log "Work dir : ${VM_MOUNT_PATH}"
    fi
    log "ZFS pool : ${ZFS_POOL}"
}

# ---------------------------------------------------------------------------
# Cargo / Rust helpers (used by vm-build.sh)
# ---------------------------------------------------------------------------

# Run a cargo command on the target, sourcing ~/.cargo/env first.
remote_cargo() {
    local cargo_cmd="$1"
    remote_exec "source \"\$HOME/.cargo/env\" && ${cargo_cmd}"
}

# ---------------------------------------------------------------------------
# Systemd helpers
# ---------------------------------------------------------------------------

# remote_service_active <service>
# Returns 0 if the service is active on the target, non-zero otherwise.
remote_service_active() {
    local svc="$1"
    remote_exec_sudo "systemctl is-active --quiet ${svc}" &>/dev/null
}

# remote_service_restart <service>
remote_service_restart() {
    local svc="$1"
    remote_exec_sudo "systemctl restart ${svc}"
}

# remote_service_stop <service>
remote_service_stop() {
    local svc="$1"
    remote_exec_sudo "systemctl stop ${svc}"
}

# ---------------------------------------------------------------------------
# ZFS pool helpers
# ---------------------------------------------------------------------------

# ensure_pool_imported <pool-name>
# Import the pool if it isn't already, using the loopback service on local VMs
# or a plain zpool import on remote hosts.
ensure_pool_imported() {
    local pool="${1:-${ZFS_POOL}}"
    remote_exec_sudo "
        if zpool list '${pool}' &>/dev/null; then
            echo 'Pool ${pool} already imported.'
        elif systemctl cat zfs-loopback-pool.service &>/dev/null; then
            echo 'Importing ${pool} via loopback service ...'
            systemctl start zfs-loopback-pool.service || true
            sleep 1
            zpool list '${pool}' && echo 'Pool imported.' \
                || echo 'WARNING: pool ${pool} still not available.'
        else
            echo 'Attempting plain zpool import ...'
            zpool import '${pool}' 2>/dev/null \
                && echo 'Pool imported.' \
                || echo 'WARNING: could not import pool ${pool}.'
        fi
    "
}

# export_pool <pool-name>
export_pool() {
    local pool="${1:-${ZFS_POOL}}"
    remote_exec_sudo "
        if zpool list '${pool}' &>/dev/null; then
            zpool export '${pool}' && echo 'Pool ${pool} exported.'
        else
            echo 'Pool ${pool} not imported — skipping export.'
        fi
    " || warn "Could not export ZFS pool '${pool}'."
}
