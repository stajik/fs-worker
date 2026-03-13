#!/usr/bin/env bash
# =============================================================================
# vm-setup.sh — Provision the Multipass ZFS development VM
#
# What this script does:
#   1. Creates (or re-uses) a Multipass VM named "zfs-dev"
#   2. Installs ZFS kernel module + userland tools
#   3. Installs Rust (stable) and all C build dependencies
#   4. Creates a loopback-backed ZFS pool called "testpool" for testing
#   5. Mounts the host project directory into the VM
#   6. Installs the worker systemd service unit
#
# Usage:
#   ./scripts/vm-setup.sh [--recreate]
#
#   --recreate   Delete and recreate the VM from scratch
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit these if needed
# ---------------------------------------------------------------------------
VM_NAME="zfs-dev"
VM_CPUS=2
VM_MEMORY="4G"
VM_DISK="20G"
VM_IMAGE="24.04"

GRPC_PORT=50051

# The host path that will be mounted inside the VM.
# Default: the directory containing this script's parent (i.e. the project root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VM_MOUNT_PATH="/home/ubuntu/worker"

# ZFS test pool
POOL_NAME="testpool"
POOL_IMAGE_PATH="/var/lib/zfs-testpool.img"
POOL_SIZE_MB=512

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${CYAN}[vm-setup]${NC} $*"; }
ok()     { echo -e "${GREEN}[vm-setup]${NC} $*"; }
warn()   { echo -e "${YELLOW}[vm-setup]${NC} $*"; }
die()    { echo -e "${RED}[vm-setup] ERROR:${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
vm_exists()  { multipass list --format csv 2>/dev/null | grep -q "^${VM_NAME},"; }
vm_running() { multipass list --format csv 2>/dev/null | grep "^${VM_NAME}," | grep -q "Running"; }

vm_exec() {
    # Run a command inside the VM as ubuntu, sourcing cargo env when available.
    multipass exec "$VM_NAME" -- bash -c "$*"
}

vm_exec_sudo() {
    multipass exec "$VM_NAME" -- sudo bash -c "$*"
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
RECREATE=0
for arg in "$@"; do
    case "$arg" in
        --recreate) RECREATE=1 ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

# ---------------------------------------------------------------------------
# Step 1 — Create / start the VM
# ---------------------------------------------------------------------------
log "Checking Multipass VM '${VM_NAME}' ..."

if vm_exists && [[ $RECREATE -eq 1 ]]; then
    warn "Deleting existing VM '${VM_NAME}' (--recreate was passed) ..."
    multipass delete "$VM_NAME" --purge
fi

if ! vm_exists; then
    log "Creating VM '${VM_NAME}' (${VM_CPUS} CPU, ${VM_MEMORY} RAM, ${VM_DISK} disk) ..."
    multipass launch "$VM_IMAGE" \
        --name "$VM_NAME" \
        --cpus "$VM_CPUS" \
        --memory "$VM_MEMORY" \
        --disk "$VM_DISK"
    ok "VM created."
else
    log "VM '${VM_NAME}' already exists."
fi

if ! vm_running; then
    log "Starting VM '${VM_NAME}' ..."
    multipass start "$VM_NAME"
fi

ok "VM is running."

# ---------------------------------------------------------------------------
# Step 2 — Mount project directory
# ---------------------------------------------------------------------------
log "Mounting project directory into VM ..."

# Check if the mount is already active
MOUNTED=$(multipass info "$VM_NAME" 2>/dev/null | grep "$PROJECT_DIR" || true)
if [[ -z "$MOUNTED" ]]; then
    multipass mount "$PROJECT_DIR" "$VM_NAME:$VM_MOUNT_PATH"
    ok "Mounted ${PROJECT_DIR} → ${VM_NAME}:${VM_MOUNT_PATH}"
else
    ok "Mount already in place."
fi

# ---------------------------------------------------------------------------
# Step 3 — System packages
# ---------------------------------------------------------------------------
log "Updating apt and installing system dependencies ..."

vm_exec_sudo "
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        zfsutils-linux \
        zfs-dkms \
        build-essential \
        pkg-config \
        libclang-dev \
        clang \
        llvm \
        curl \
        git \
        protobuf-compiler \
        libssl-dev \
        2>&1 | tail -5
"
ok "System packages installed."

# ---------------------------------------------------------------------------
# Step 4 — Rust toolchain
# ---------------------------------------------------------------------------
log "Installing Rust stable toolchain ..."

vm_exec "
    if ! command -v rustup &>/dev/null; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --default-toolchain stable
        echo 'Rust installed.'
    else
        source \"\$HOME/.cargo/env\"
        rustup update stable
        echo 'Rust updated.'
    fi
"
ok "Rust toolchain ready."

# ---------------------------------------------------------------------------
# Step 5 — Create ZFS loopback test pool
# ---------------------------------------------------------------------------
log "Setting up ZFS test pool '${POOL_NAME}' ..."

vm_exec_sudo "
    set -euo pipefail

    # Load the ZFS kernel module if not already loaded
    if ! lsmod | grep -q '^zfs'; then
        modprobe zfs
    fi

    # Destroy existing pool if it's already imported (idempotent)
    if zpool list '${POOL_NAME}' &>/dev/null; then
        echo 'Pool already exists — skipping creation.'
        zpool status '${POOL_NAME}'
        exit 0
    fi

    # Create a sparse image file to back the pool
    mkdir -p \"\$(dirname '${POOL_IMAGE_PATH}')\"
    if [[ ! -f '${POOL_IMAGE_PATH}' ]]; then
        truncate -s ${POOL_SIZE_MB}M '${POOL_IMAGE_PATH}'
        echo 'Created pool image: ${POOL_IMAGE_PATH}'
    fi

    # Set up a loop device
    LOOP_DEV=\$(losetup --find --show '${POOL_IMAGE_PATH}')
    echo \"Using loop device: \${LOOP_DEV}\"

    # Create the pool
    zpool create -f '${POOL_NAME}' \"\${LOOP_DEV}\"
    zpool status '${POOL_NAME}'
    echo 'ZFS test pool created successfully.'
"
ok "ZFS pool '${POOL_NAME}' is ready."

# ---------------------------------------------------------------------------
# Step 6 — Persist the loopback pool across reboots
# ---------------------------------------------------------------------------
log "Installing pool persistence service ..."

vm_exec_sudo "
cat > /etc/systemd/system/zfs-loopback-pool.service <<'UNIT'
[Unit]
Description=Attach loopback device and import ZFS test pool
DefaultDependencies=no
Before=zfs-import.target
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
    LOOP=\$(losetup -j ${POOL_IMAGE_PATH} | cut -d: -f1); \
    if [ -z \"\$LOOP\" ]; then \
        LOOP=\$(losetup --find --show ${POOL_IMAGE_PATH}); \
    fi; \
    zpool import -d \"\$LOOP\" ${POOL_NAME} 2>/dev/null || true'
ExecStop=/bin/bash -c 'zpool export ${POOL_NAME} 2>/dev/null || true'

[Install]
WantedBy=zfs-import.target
UNIT

    systemctl daemon-reload
    systemctl enable zfs-loopback-pool.service
    echo 'Persistence service installed.'
"
ok "Pool persistence service installed."

# ---------------------------------------------------------------------------
# Step 7 — Install worker systemd service
# ---------------------------------------------------------------------------
log "Installing worker gRPC service unit ..."

vm_exec_sudo "
cat > /etc/systemd/system/worker.service <<'UNIT'
[Unit]
Description=Worker gRPC service
After=network.target zfs-import.target zfs-loopback-pool.service
Wants=zfs-loopback-pool.service

[Service]
Type=simple
User=ubuntu
WorkingDirectory=${VM_MOUNT_PATH}
Environment=RUST_LOG=info
ExecStartPre=/bin/bash -c 'source /home/ubuntu/.cargo/env && cargo build --release --manifest-path ${VM_MOUNT_PATH}/Cargo.toml'
ExecStart=${VM_MOUNT_PATH}/target/release/worker
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    echo 'Worker service unit installed.'
"
ok "Worker service unit installed."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
VM_IP=$(multipass info "$VM_NAME" | awk '/IPv4/ {print $2}')

echo ""
ok "============================================================"
ok "  VM '${VM_NAME}' is ready!"
ok "  IP address : ${VM_IP}"
ok "  gRPC port  : ${GRPC_PORT}  (use vm-port-forward.sh)"
ok "  ZFS pool   : ${POOL_NAME}"
ok "  Source dir : ${VM_MOUNT_PATH}"
ok ""
ok "  Next steps:"
ok "    ./scripts/vm-build.sh          # compile inside the VM"
ok "    ./scripts/vm-run.sh            # start the worker"
ok "    ./scripts/vm-port-forward.sh   # forward grpc port to localhost"
ok "    ./scripts/vm-test.sh           # run smoke tests"
ok "    ./scripts/vm-shell.sh          # open a shell in the VM"
ok "============================================================"
