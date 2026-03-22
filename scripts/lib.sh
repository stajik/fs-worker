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
#   REMOTE_WORK_DIR=/home/worker/fs-worker  # project dir on remote
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
                # Expand a leading ~ in the value (e.g. REMOTE_PEM=~/.ssh/key.pem)
                local key="${line%%=*}"
                local val="${line#*=}"
                if [[ "$val" == "~/"* ]]; then
                    val="${HOME}${val:1}"
                fi
                export "${key}=${val}"
            fi
        done < "${ENV_FILE}"
    fi
}

load_env

# ---------------------------------------------------------------------------
# Defaults (can be overridden in .env or environment)
# ---------------------------------------------------------------------------
VM_NAME="${VM_NAME:-zfs-dev}"
VM_MOUNT_PATH="${VM_MOUNT_PATH:-/home/worker/fs-worker}"

REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-ubuntu}"
REMOTE_PEM="${REMOTE_PEM:-}"
REMOTE_PORT="${REMOTE_PORT:-22}"
REMOTE_WORK_DIR="${REMOTE_WORK_DIR:-/home/worker/fs-worker}"
REMOTE_POOL_DEVICE="${REMOTE_POOL_DEVICE:-}"   # e.g. /dev/nvme1n1 — EBS volume on remote

# AWS variables — only needed when interacting with AWS (e.g. security group updates)
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_SG_ID="${AWS_SG_ID:-}"

ZFS_POOL="${ZFS_POOL:-testpool}"
WORKER_USER="${WORKER_USER:-worker}"

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
        [[ -n "${REMOTE_POOL_DEVICE}" ]] || die \
            "Remote mode requires REMOTE_POOL_DEVICE (e.g. /dev/nvme1n1). Set it in ${ENV_FILE}."
        command -v ssh  &>/dev/null || die "ssh is not installed or not in PATH."
        command -v rsync &>/dev/null || die "rsync is not installed or not in PATH."
        # Initialise the SSH_OPTS array now that all REMOTE_* vars are validated.
        _ssh_opts_init
    else
        command -v multipass &>/dev/null || die \
            "multipass is not installed or not in PATH. Install it or use --remote mode."
    fi
}

# ---------------------------------------------------------------------------
# SSH base options (shared by exec and tunnel functions)
# ---------------------------------------------------------------------------
# An array is used instead of a string function so every element is passed as
# a separate, properly-quoted argument to ssh — no word-splitting surprises.
# Usage:  ssh "${SSH_OPTS[@]}" user@host ...
#
# Call _ssh_opts_init once after REMOTE_* vars are finalised (validate_mode
# does this automatically).  All transport functions reference SSH_OPTS.
#
# ControlMaster multiplexing:
#   The first SSH call opens a master connection and keeps it alive for
#   SSH_CONTROL_PERSIST seconds (10 min by default).  Every subsequent call
#   reuses that single TCP connection instantly — no new handshake, no new
#   connection-tracking entry, no post-quantum key-exchange delay.
#   The socket file lives in /tmp and is scoped to this host+user+port so
#   multiple concurrent script runs against different hosts don't collide.
SSH_OPTS=()
_SSH_CONTROL_PATH=""

_ssh_opts_init() {
    # One socket per host/user/port combination so parallel runs don't collide.
    _SSH_CONTROL_PATH="/tmp/fs-worker-ssh-${REMOTE_USER}-${REMOTE_HOST}-${REMOTE_PORT}.sock"

    SSH_OPTS=(
        -i "${REMOTE_PEM}"
        -p "${REMOTE_PORT}"
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
        -o ServerAliveInterval=10
        -o ServerAliveCountMax=6
        -o ConnectTimeout=60
        -o TCPKeepAlive=yes
        # Prefer curve25519 over the post-quantum sntrup761 hybrid — the latter
        # is CPU-intensive and causes 30-50s handshake delays on loaded
        # bare-metal instances.  curve25519 is still cryptographically strong.
        -o KexAlgorithms=curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group14-sha256
        # Multiplexing — reuse one TCP connection for all ssh/rsync calls.
        -o ControlMaster=auto
        -o ControlPath="${_SSH_CONTROL_PATH}"
        -o ControlPersist=600
    )
}

# ssh_master_stop
# Explicitly close the ControlMaster connection.  Safe to call even if it is
# not running.  Scripts that want a clean teardown can call this at exit.
ssh_master_stop() {
    [[ -z "${_SSH_CONTROL_PATH}" ]] && return 0
    ssh -O stop \
        -o ControlPath="${_SSH_CONTROL_PATH}" \
        "${REMOTE_USER}@${REMOTE_HOST}" &>/dev/null || true
}

# ---------------------------------------------------------------------------
# Unified transport functions
# ---------------------------------------------------------------------------

# remote_exec <cmd-string>
# Run a bash command on the target (as the remote user).
remote_exec() {
    local cmd="$1"
    if [[ "${MODE}" == "remote" ]]; then
        ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "bash -c $(printf '%q' "$cmd")"
    else
        multipass exec "${VM_NAME}" -- bash -c "$cmd"
    fi
}

# remote_exec_sudo <cmd-string>
# Run a bash command on the target as root.
remote_exec_sudo() {
    local cmd="$1"
    if [[ "${MODE}" == "remote" ]]; then
        ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "sudo bash -c $(printf '%q' "$cmd")"
    else
        multipass exec "${VM_NAME}" -- sudo bash -c "$cmd"
    fi
}

# remote_exec_as_worker <cmd-string>
# Run a bash command on the target as the WORKER_USER.
remote_exec_as_worker() {
    local cmd="$1"
    local wrapped="cd $(remote_work_dir) && ${cmd}"
    if [[ "${MODE}" == "remote" ]]; then
        ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "sudo -u ${WORKER_USER} bash -c $(printf '%q' "$wrapped")"
    else
        multipass exec "${VM_NAME}" -- sudo -u "${WORKER_USER}" bash -c "$wrapped"
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
        # rsync -e takes a shell command string.  Building that string from
        # SSH_OPTS with printf %q over-escapes (e.g. commas in KexAlgorithms
        # become \, which ssh rejects).  Instead write a tiny wrapper script
        # that calls ssh with the array directly — no string interpolation.
        local _ssh_wrapper
        _ssh_wrapper=$(mktemp /tmp/fs-worker-rsync-ssh-XXXXXX)
        chmod +x "${_ssh_wrapper}"
        # Write the wrapper, embedding the array elements as a quoted list.
        {
            echo "#!/usr/bin/env bash"
            printf 'exec ssh'
            printf ' %q' "${SSH_OPTS[@]}"
            printf ' "$@"\n'
        } > "${_ssh_wrapper}"

        rsync -az --delete \
            -e "${_ssh_wrapper}" \
            --rsync-path='sudo rsync' \
            "${src}" \
            "${REMOTE_USER}@${REMOTE_HOST}:${dst}"
        local _rc=$?
        rm -f "${_ssh_wrapper}"
        # Restore ownership to the worker user
        if [[ $_rc -eq 0 ]]; then
            ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" \
                "sudo chown -R ${WORKER_USER}:${WORKER_USER} '${dst}'"
        fi
        return $_rc
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
        local ssh_err
        ssh_err=$(ssh "${SSH_OPTS[@]}" \
            "${REMOTE_USER}@${REMOTE_HOST}" "echo ok" 2>&1)
        # Test exit code separately — the || must bind to ssh, not to the assignment
        # shellcheck disable=SC2181
        if [[ $? -ne 0 ]]; then
            die "Cannot reach ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT} — ${ssh_err}.
Check REMOTE_HOST, REMOTE_USER, REMOTE_PEM and REMOTE_PORT in ${ENV_FILE}."
        fi
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
        log "Pool dev : ${REMOTE_POOL_DEVICE}"
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
# Security group helper
# ---------------------------------------------------------------------------

# ensure_sg_allows_current_ip
# Looks up the current public IP and ensures the security group in AWS_SG_ID
# has an SSH ingress rule for it.  Silently skips if AWS_SG_ID or the AWS CLI
# are not available (e.g. in local Multipass mode).
ensure_sg_allows_current_ip() {
    [[ "${MODE}" != "remote" ]] && return 0
    command -v aws &>/dev/null        || return 0
    [[ -n "${AWS_SG_ID:-}" ]]         || return 0

    local my_ip my_cidr rule_exists
    my_ip=$(curl -sf https://checkip.amazonaws.com \
         || curl -sf https://api.ipify.org \
         || true)

    if [[ -z "$my_ip" ]]; then
        warn "Could not determine current public IP — skipping security group check."
        return 0
    fi

    my_cidr="${my_ip}/32"

    # Build the aws command with optional --profile / --region flags,
    # mirroring what vm-provision.sh does via its aws() wrapper.
    local aws_cmd=(command aws)
    [[ -n "${AWS_PROFILE:-}" ]] && aws_cmd+=(--profile "${AWS_PROFILE}")
    [[ -n "${AWS_REGION:-}"  ]] && aws_cmd+=(--region  "${AWS_REGION}")

    rule_exists=$("${aws_cmd[@]}" ec2 describe-security-groups \
        --group-ids "${AWS_SG_ID}" \
        --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`] \
| [0].IpRanges[?CidrIp=='${my_cidr}'] | [0].CidrIp" \
        --output text 2>/dev/null || true)

    if [[ -z "$rule_exists" || "$rule_exists" == "None" ]]; then
        log "Current IP ${my_ip} not in security group ${AWS_SG_ID} — adding SSH rule ..."
        "${aws_cmd[@]}" ec2 authorize-security-group-ingress \
            --group-id "${AWS_SG_ID}" \
            --protocol tcp \
            --port 22 \
            --cidr "${my_cidr}" 2>/dev/null || true
        ok "SSH (port 22) opened for ${my_cidr}."
    else
        log "Security group already allows SSH from ${my_cidr}."
    fi
}

# ---------------------------------------------------------------------------
# Temporal connectivity helpers
# ---------------------------------------------------------------------------

# _temporal_host_port
# Parse TEMPORAL_HOST (e.g. "http://localhost:7233") into host and port.
# Prints "<host> <port>" on stdout.
_temporal_host_port() {
    local raw="${TEMPORAL_HOST:-http://localhost:7233}"
    # Strip scheme
    raw="${raw#http://}"
    raw="${raw#https://}"
    local host="${raw%%:*}"
    local port="${raw##*:}"
    # Default port if not specified
    [[ "$port" == "$host" ]] && port="7233"
    echo "${host} ${port}"
}

# ensure_temporal_reachable
# In local/remote mode, if the Temporal server is on the Mac (localhost),
# set up a reverse SSH tunnel so the target can reach it at localhost:<port>.
#
# Uses SSH -R (reverse forward): a connection to localhost:<port> on the
# target is forwarded back to <host>:<port> on the Mac.
#
# The tunnel runs in the background; its PID is stored in
# .vm-temporal-tunnel.pid next to the scripts directory.
# Safe to call multiple times — no-ops if a live tunnel already exists.
TEMPORAL_TUNNEL_PID_FILE="${_LIB_DIR}/.vm-temporal-tunnel.pid"

ensure_temporal_reachable() {
    # Only needed when we have a remote target (VM or bare-metal).
    # In a purely local process there is nothing to tunnel.
    if [[ "${MODE}" == "local" ]]; then
        # Multipass VMs on macOS can reach the Mac via the host gateway.
        # Check whether the worker can already reach Temporal; if the host
        # is "localhost" we need to substitute the Mac's address in the VM.
        local host port
        read -r host port < <(_temporal_host_port)
        if [[ "$host" == "localhost" || "$host" == "127.0.0.1" ]]; then
            # Multipass exposes the Mac as the default gateway inside the VM.
            local mac_ip
            mac_ip=$(multipass exec "${VM_NAME}" -- \
                ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -1 || true)
            if [[ -n "$mac_ip" ]]; then
                log "Temporal is on Mac localhost — worker will reach it at ${mac_ip}:${port} inside the VM."
                log "  Set TEMPORAL_HOST=http://${mac_ip}:${port} in .env to make this permanent."
                export TEMPORAL_HOST="http://${mac_ip}:${port}"
            else
                warn "Could not determine Mac IP inside VM. Worker may fail to reach Temporal."
                warn "  Set TEMPORAL_HOST in .env to the Mac's IP as seen from inside the VM."
            fi
        fi
        return 0
    fi

    # --- Remote (SSH) mode below ---
    local host port
    read -r host port < <(_temporal_host_port)

    # If Temporal is not on localhost there is nothing to tunnel.
    if [[ "$host" != "localhost" && "$host" != "127.0.0.1" ]]; then
        log "TEMPORAL_HOST points to ${host}:${port} — assuming reachable from target, skipping tunnel."
        return 0
    fi

    # Kill any stale tunnel for this port.
    if [[ -f "$TEMPORAL_TUNNEL_PID_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$TEMPORAL_TUNNEL_PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            # Verify it is still forwarding the right port before reusing.
            if ssh -O check \
                   -o ControlPath="${_SSH_CONTROL_PATH}" \
                   "${REMOTE_USER}@${REMOTE_HOST}" &>/dev/null; then
                log "Reverse Temporal tunnel already active (PID ${old_pid})."
                return 0
            fi
            kill "$old_pid" 2>/dev/null || true
        fi
        rm -f "$TEMPORAL_TUNNEL_PID_FILE"
    fi

    log "Setting up reverse tunnel: target:${port} → Mac localhost:${port} ..."

    # -R <port>:localhost:<port>  — on the target, connections to localhost:<port>
    #                               are forwarded back to this Mac's localhost:<port>.
    # -N                          — no remote command, tunnel only.
    # -f                          — go to background after authentication.
    # GatewayPorts no (default)   — the -R bind is restricted to loopback on target,
    #                               which is exactly what we want.
    ssh "${SSH_OPTS[@]}" \
        -N \
        -f \
        -R "${port}:localhost:${port}" \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=4 \
        "${REMOTE_USER}@${REMOTE_HOST}"

    # Capture the PID of the background ssh process we just spawned.
    # `ssh -f` daemonises, so we find it by its control socket argument.
    local tunnel_pid
    tunnel_pid=$(pgrep -n -f "ssh.*-R ${port}:localhost:${port}.*${REMOTE_HOST}" || true)
    if [[ -n "$tunnel_pid" ]]; then
        echo "$tunnel_pid" > "$TEMPORAL_TUNNEL_PID_FILE"
    fi

    # Give the tunnel a moment to establish, then verify.
    sleep 1
    if remote_exec "bash -c 'echo >/dev/tcp/localhost/${port}' 2>/dev/null && echo ok || echo fail" \
           2>/dev/null | grep -q "ok"; then
        ok "Reverse Temporal tunnel active — target:${port} → Mac:${port}."
    else
        warn "Reverse tunnel established but Temporal may not be listening on Mac localhost:${port}."
        warn "  Make sure 'temporal server start-dev' is running on your Mac."
    fi
}

# temporal_tunnel_stop
# Tear down a background reverse Temporal tunnel started by ensure_temporal_reachable.
temporal_tunnel_stop() {
    if [[ -f "$TEMPORAL_TUNNEL_PID_FILE" ]]; then
        local pid
        pid=$(cat "$TEMPORAL_TUNNEL_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            ok "Temporal reverse tunnel (PID ${pid}) stopped."
        fi
        rm -f "$TEMPORAL_TUNNEL_PID_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Go helpers (used by vm-build.sh)
# ---------------------------------------------------------------------------

# Run a Go command on the target.
remote_go() {
    local go_cmd="$1"
    remote_exec "${go_cmd}"
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
