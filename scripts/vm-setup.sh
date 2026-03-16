#!/usr/bin/env bash
# =============================================================================
# vm-setup.sh — Provision the development environment
#
# Local mode  (default):  creates and provisions a Multipass VM
# Remote mode (--remote): provisions a bare-metal machine over SSH
#                         credentials are read from .env in the project root
#
# Usage:
#   ./scripts/vm-setup.sh [--remote] [--recreate]
#
#   --remote     Target the SSH bare-metal host defined in .env
#   --recreate   (local only) Delete and recreate the VM from scratch
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PREFIX="[vm-setup]"
source "${SCRIPT_DIR}/lib.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VM_CPUS=2
VM_MEMORY="4G"
VM_DISK="20G"
VM_IMAGE="24.04"

POOL_NAME="${ZFS_POOL}"
POOL_IMAGE_PATH="/var/lib/zfs-${POOL_NAME}.img"
POOL_SIZE_MB=512

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
RECREATE=0
parse_mode_flag "$@"
set -- "${FILTERED_ARGS[@]}"

for arg in "$@"; do
    case "$arg" in
        --recreate) RECREATE=1 ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

validate_mode
WORK_DIR="$(remote_work_dir)"

print_mode_banner
echo ""

# ---------------------------------------------------------------------------
# LOCAL MODE — create/start the Multipass VM
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "local" ]]; then
    vm_exists()  { multipass list --format csv 2>/dev/null | grep -q "^${VM_NAME},"; }
    vm_running() { multipass list --format csv 2>/dev/null | grep "^${VM_NAME}," | grep -q "Running"; }

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

    # Mount project directory
    log "Mounting project directory into VM ..."
    MOUNTED=$(multipass info "$VM_NAME" 2>/dev/null | grep "$PROJECT_DIR" || true)
    if [[ -z "$MOUNTED" ]]; then
        multipass mount "$PROJECT_DIR" "$VM_NAME:$WORK_DIR"
        ok "Mounted ${PROJECT_DIR} → ${VM_NAME}:${WORK_DIR}"
    else
        ok "Mount already in place."
    fi
else
    # REMOTE MODE — verify connectivity
    log "Checking connectivity to ${REMOTE_USER}@${REMOTE_HOST} ..."
    remote_check_reachable
    ok "Host is reachable."

    # Ensure the work directory exists on the remote
    log "Ensuring work directory '${WORK_DIR}' exists on remote ..."
    remote_exec "mkdir -p '${WORK_DIR}'"

    # Sync the project source to the remote host
    log "Syncing project source to remote ..."
    remote_copy "${PROJECT_DIR}/" "${WORK_DIR}/"
    ok "Source synced."
fi

# ---------------------------------------------------------------------------
# Step: System packages (both modes)
# ---------------------------------------------------------------------------
log "Updating apt and installing system dependencies ..."

remote_exec_sudo "
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
        rsync \
        2>&1 | tail -5
"
ok "System packages installed."

# ---------------------------------------------------------------------------
# Step: Rust toolchain (both modes)
# ---------------------------------------------------------------------------
log "Installing Rust stable toolchain ..."

remote_exec "
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
# Step: ZFS pool setup (both modes)
# ---------------------------------------------------------------------------
log "Setting up ZFS pool '${POOL_NAME}' ..."

remote_exec_sudo "
    set -euo pipefail

    # Load the ZFS kernel module if not already loaded
    if ! lsmod | grep -q '^zfs'; then
        modprobe zfs
    fi

    # Idempotent: skip if pool is already imported
    if zpool list '${POOL_NAME}' &>/dev/null; then
        echo 'Pool already exists — skipping creation.'
        zpool status '${POOL_NAME}'
        exit 0
    fi

    mkdir -p \"\$(dirname '${POOL_IMAGE_PATH}')\"
    if [[ ! -f '${POOL_IMAGE_PATH}' ]]; then
        truncate -s ${POOL_SIZE_MB}M '${POOL_IMAGE_PATH}'
        echo 'Created pool image: ${POOL_IMAGE_PATH}'
    fi

    LOOP_DEV=\$(losetup --find --show '${POOL_IMAGE_PATH}')
    echo \"Using loop device: \${LOOP_DEV}\"

    zpool create -f '${POOL_NAME}' \"\${LOOP_DEV}\"
    zpool status '${POOL_NAME}'
    echo 'ZFS pool created successfully.'
"
ok "ZFS pool '${POOL_NAME}' is ready."

# ---------------------------------------------------------------------------
# Step: Pool persistence service (both modes)
# ---------------------------------------------------------------------------
log "Installing pool persistence service ..."

remote_exec_sudo "
cat > /etc/systemd/system/zfs-loopback-pool.service <<'UNIT'
[Unit]
Description=Attach loopback device and import ZFS pool ${POOL_NAME}
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
    echo 'Pool persistence service installed.'
"
ok "Pool persistence service installed."

# ---------------------------------------------------------------------------
# Step: Worker systemd service (both modes)
# ---------------------------------------------------------------------------
log "Installing worker systemd service unit ..."

remote_exec_sudo "
cat > /etc/systemd/system/fs-worker.service <<'UNIT'
[Unit]
Description=fs-worker Temporal activity worker
After=network.target zfs-import.target zfs-loopback-pool.service
Wants=zfs-loopback-pool.service

[Service]
Type=simple
User=${REMOTE_USER:-ubuntu}
WorkingDirectory=${WORK_DIR}
Environment=RUST_LOG=info
Environment=ZFS_POOL=${POOL_NAME}
ExecStartPre=/bin/bash -c 'source /home/${REMOTE_USER:-ubuntu}/.cargo/env && cargo build --release --manifest-path ${WORK_DIR}/Cargo.toml'
ExecStart=${WORK_DIR}/target/release/fs-worker
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    echo 'fs-worker service unit installed.'
"
ok "Worker service unit installed."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
TARGET_IP="$(remote_ip)"

echo ""
ok "============================================================"
if [[ "${MODE}" == "remote" ]]; then
    ok "  Remote host '${REMOTE_HOST}' is ready!"
else
    ok "  VM '${VM_NAME}' is ready!"
fi
ok "  IP / host  : ${TARGET_IP}"
ok "  ZFS pool   : ${POOL_NAME}"
ok "  Work dir   : ${WORK_DIR}"
ok ""
ok "  Next steps:"
ok "    ./scripts/vm-build.sh          # compile on the target"
ok "    ./scripts/vm-run.sh            # start the worker"
ok "    ./scripts/vm-port-forward.sh   # forward Temporal port to localhost"
ok "    ./scripts/vm-test.sh           # run smoke tests"
ok "    ./scripts/vm-shell.sh          # open a shell on the target"
ok "============================================================"
