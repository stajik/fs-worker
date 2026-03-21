#!/usr/bin/env bash
# =============================================================================
# vm-port-forward.sh — Forward the worker metrics port to localhost
#
# Local mode  (default):  tunnels through the Multipass VM
# Remote mode (--remote): tunnels through the bare-metal SSH host in .env
#
# Usage:
#   ./scripts/vm-port-forward.sh [--remote] [--port <local-port>] [--background]
#   ./scripts/vm-port-forward.sh [--remote] --stop
#
#   --remote        Target the SSH bare-metal host defined in .env
#   --port <n>      Local port to bind (default: 9090)
#   --background    Run the tunnel in the background (PID saved to .vm-tunnel.pid)
#   --stop          Kill a previously backgrounded tunnel
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PREFIX="[port-forward]"
source "${SCRIPT_DIR}/lib.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
REMOTE_METRICS_PORT=9090    # Prometheus metrics port on the target
LOCAL_PORT=9090
PID_FILE="${SCRIPT_DIR}/.vm-tunnel.pid"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
BACKGROUND=0
STOP=0

parse_mode_flag "$@"
set -- "${FILTERED_ARGS[@]}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)
            [[ -n "${2:-}" ]] || die "--port requires an argument."
            LOCAL_PORT="$2"
            shift 2
            ;;
        --background) BACKGROUND=1; shift ;;
        --stop)       STOP=1;       shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# Stop a background tunnel
# ---------------------------------------------------------------------------
if [[ $STOP -eq 1 ]]; then
    if [[ -f "$PID_FILE" ]]; then
        TUNNEL_PID=$(cat "$PID_FILE")
        if kill -0 "$TUNNEL_PID" 2>/dev/null; then
            kill "$TUNNEL_PID"
            ok "Tunnel (PID ${TUNNEL_PID}) stopped."
        else
            warn "Tunnel PID ${TUNNEL_PID} is no longer running."
        fi
        rm -f "$PID_FILE"
    else
        warn "No PID file found at ${PID_FILE}. Nothing to stop."
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Validate mode and connectivity
# ---------------------------------------------------------------------------
validate_mode
remote_check_reachable

command -v ssh &>/dev/null || die "ssh is not installed or not in PATH."

# Check if local port is already in use
if lsof -iTCP:"${LOCAL_PORT}" -sTCP:LISTEN &>/dev/null; then
    if [[ -f "$PID_FILE" ]]; then
        TUNNEL_PID=$(cat "$PID_FILE")
        if kill -0 "$TUNNEL_PID" 2>/dev/null; then
            warn "A tunnel is already running on localhost:${LOCAL_PORT} (PID ${TUNNEL_PID})."
            warn "Use --stop to terminate it first."
            exit 0
        fi
    fi
    die "Port ${LOCAL_PORT} is already in use. Use --port <n> to choose a different local port."
fi

# ---------------------------------------------------------------------------
# Resolve SSH connection parameters
# ---------------------------------------------------------------------------
# In remote mode the key is always known from .env.
# In local mode we locate the Multipass-managed key.

TARGET_IP="$(remote_ip)"
[[ -z "$TARGET_IP" ]] && die "Could not determine IP address of target."

if [[ "${MODE}" == "remote" ]]; then
    SSH_KEY="${REMOTE_PEM}"
    SSH_USER="${REMOTE_USER}"
    SSH_PORT="${REMOTE_PORT}"
else
    # Locate the Multipass SSH key
    MULTIPASS_DATA_DIRS=(
        "${HOME}/Library/Application Support/multipassd/ssh-keys"
        "/var/root/Library/Application Support/multipassd/ssh-keys"
        "/var/snap/multipass/common/data/multipassd/ssh-keys"
        "/var/lib/multipass/ssh-keys"
    )
    SSH_KEY=""
    for dir in "${MULTIPASS_DATA_DIRS[@]}"; do
        candidate="${dir}/id_rsa"
        if [[ -f "$candidate" ]]; then
            SSH_KEY="$candidate"
            break
        fi
    done
    SSH_USER="ubuntu"
    SSH_PORT="22"
fi

# ---------------------------------------------------------------------------
# Build SSH tunnel command
# ---------------------------------------------------------------------------
# -N  : no remote command
# -T  : no PTY
# -L  : local port forward
SSH_OPTS=(
    -N -T
    -L "${LOCAL_PORT}:localhost:${REMOTE_METRICS_PORT}"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
    -o ExitOnForwardFailure=yes
    -p "${SSH_PORT}"
)

if [[ -n "${SSH_KEY}" ]]; then
    SSH_CMD=(ssh "${SSH_OPTS[@]}" -i "${SSH_KEY}" "${SSH_USER}@${TARGET_IP}")
else
    warn "Could not locate SSH key — attempting connection without explicit key."
    SSH_CMD=(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${TARGET_IP}")
fi

log "Tunnel: localhost:${LOCAL_PORT} → ${TARGET_IP}:${REMOTE_METRICS_PORT} (metrics)"
print_mode_banner
echo ""

# ---------------------------------------------------------------------------
# Kill any stale backgrounded tunnel
# ---------------------------------------------------------------------------
if [[ -f "$PID_FILE" ]]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        warn "Killing stale tunnel (PID ${OLD_PID}) ..."
        kill "$OLD_PID" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$PID_FILE"
fi

# ---------------------------------------------------------------------------
# Launch the tunnel
# ---------------------------------------------------------------------------
if [[ $BACKGROUND -eq 1 ]]; then
    log "Starting tunnel in background ..."
    "${SSH_CMD[@]}" &
    TUNNEL_PID=$!
    echo "$TUNNEL_PID" > "$PID_FILE"

    sleep 2
    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
        rm -f "$PID_FILE"
        die "Tunnel process exited immediately. Is the worker running on the target?"
    fi

    ok "Tunnel running in the background (PID ${TUNNEL_PID})."
    ok "  Metrics: localhost:${LOCAL_PORT} → ${TARGET_IP}:${REMOTE_METRICS_PORT}"
    ok ""
    ok "  To stop the tunnel:"
    ok "    ./scripts/vm-port-forward.sh --stop"
else
    ok "Tunnel active — localhost:${LOCAL_PORT} → ${TARGET_IP}:${REMOTE_METRICS_PORT} (metrics)"
    ok "Press Ctrl-C to close the tunnel."
    echo ""
    "${SSH_CMD[@]}"
fi
