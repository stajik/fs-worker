#!/usr/bin/env bash
# =============================================================================
# vm-port-forward.sh — Forward the VM's gRPC port to localhost
#
# Establishes an SSH tunnel from localhost:50051 → VM:50051 so you can point
# gRPC clients at localhost:50051 from your Mac without knowing the VM's IP.
#
# Usage:
#   ./scripts/vm-port-forward.sh [--port <local-port>] [--background]
#
#   --port <n>    Local port to bind (default: 50051)
#   --background  Run the tunnel in the background (writes PID to .vm-tunnel.pid)
#   --stop        Kill a previously backgrounded tunnel
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_NAME="zfs-dev"
REMOTE_PORT=50051
LOCAL_PORT=50051
PID_FILE="${SCRIPT_DIR}/.vm-tunnel.pid"
SSH_KEY_DIR="${HOME}/.ssh"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[port-forward]${NC} $*"; }
ok()   { echo -e "${GREEN}[port-forward]${NC} $*"; }
warn() { echo -e "${YELLOW}[port-forward]${NC} $*"; }
die()  { echo -e "${RED}[port-forward] ERROR:${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
BACKGROUND=0
STOP=0
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
# Sanity checks
# ---------------------------------------------------------------------------
command -v multipass &>/dev/null || die "multipass is not installed or not in PATH."
command -v ssh       &>/dev/null || die "ssh is not installed or not in PATH."

VM_STATE=$(multipass list --format csv 2>/dev/null | grep "^${VM_NAME}," | cut -d',' -f2 || true)
[[ -z "$VM_STATE" ]]           && die "VM '${VM_NAME}' does not exist. Run ./scripts/vm-setup.sh first."
[[ "$VM_STATE" != "Running" ]] && die "VM '${VM_NAME}' is not running. Start it with: multipass start ${VM_NAME}"

# Check if local port is already in use
if lsof -iTCP:"${LOCAL_PORT}" -sTCP:LISTEN &>/dev/null; then
    # If we already have a tunnel for this port, mention it specifically
    if [[ -f "$PID_FILE" ]]; then
        TUNNEL_PID=$(cat "$PID_FILE")
        if kill -0 "$TUNNEL_PID" 2>/dev/null; then
            warn "A tunnel is already running on localhost:${LOCAL_PORT} (PID ${TUNNEL_PID})."
            warn "Use --stop to terminate it first."
            exit 0
        fi
    fi
    die "Port ${LOCAL_PORT} is already in use by another process. Use --port <n> to choose a different local port."
fi

# ---------------------------------------------------------------------------
# Locate the Multipass SSH key for this VM
# ---------------------------------------------------------------------------
# Multipass stores per-instance keys under its data directory.
# Fall back to the global key if the per-instance one isn't found.
MULTIPASS_DATA_DIRS=(
    "${HOME}/Library/Application Support/multipassd/ssh-keys"  # macOS (user)
    "/var/root/Library/Application Support/multipassd/ssh-keys" # macOS (root daemon)
    "/var/snap/multipass/common/data/multipassd/ssh-keys"        # Linux snap
    "/var/lib/multipass/ssh-keys"                                # Linux package
)

SSH_KEY=""
for dir in "${MULTIPASS_DATA_DIRS[@]}"; do
    candidate="${dir}/id_rsa"
    if [[ -f "$candidate" ]]; then
        SSH_KEY="$candidate"
        break
    fi
done

if [[ -z "$SSH_KEY" ]]; then
    # Last resort: try the key embedded in the multipass info output
    warn "Could not locate Multipass SSH key automatically."
    warn "Falling back to: multipass exec (which uses its own SSH internally)."
    USE_MULTIPASS_EXEC=1
else
    USE_MULTIPASS_EXEC=0
    log "Using SSH key: ${SSH_KEY}"
fi

# ---------------------------------------------------------------------------
# Get the VM's IP address
# ---------------------------------------------------------------------------
VM_IP=$(multipass info "$VM_NAME" 2>/dev/null | awk '/IPv4/ {print $2}' | head -1)
[[ -z "$VM_IP" ]] && die "Could not determine IP address of VM '${VM_NAME}'."

log "VM IP : ${VM_IP}"
log "Tunnel: localhost:${LOCAL_PORT} → ${VM_IP}:${REMOTE_PORT}"

# ---------------------------------------------------------------------------
# Build the SSH tunnel command
# ---------------------------------------------------------------------------
# -N        : don't execute a remote command
# -T        : disable pseudo-terminal allocation
# -L        : local port forwarding
# -o ...    : suppress host-key prompts / keep-alive
SSH_OPTS=(
    -N
    -T
    -L "${LOCAL_PORT}:localhost:${REMOTE_PORT}"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
    -o ExitOnForwardFailure=yes
)

if [[ $USE_MULTIPASS_EXEC -eq 0 ]]; then
    SSH_CMD=(ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "ubuntu@${VM_IP}")
else
    # Build a wrapper that tunnels via `multipass exec` — less reliable but
    # works when the key path cannot be determined.
    SSH_CMD=(ssh "${SSH_OPTS[@]}" "ubuntu@${VM_IP}")
fi

# ---------------------------------------------------------------------------
# Kill any stale backgrounded tunnel for this port
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

    # Give it a moment to establish
    sleep 2
    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
        rm -f "$PID_FILE"
        die "Tunnel process exited immediately. Check that the worker is running in the VM."
    fi

    ok "Tunnel is running in the background (PID ${TUNNEL_PID})."
    ok "  Local endpoint : localhost:${LOCAL_PORT}"
    ok "  Remote         : ${VM_IP}:${REMOTE_PORT}"
    ok ""
    ok "  To stop the tunnel:"
    ok "    ./scripts/vm-port-forward.sh --stop"
else
    ok "Tunnel active — localhost:${LOCAL_PORT} → ${VM_IP}:${REMOTE_PORT}"
    ok "Press Ctrl-C to close the tunnel."
    echo ""
    "${SSH_CMD[@]}"
fi
