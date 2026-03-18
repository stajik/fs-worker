#!/usr/bin/env bash
# =============================================================================
# vm-setup.sh — Provision the development environment (including ZFS base volume)
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
# Local (loopback) mode only — not used in remote mode
POOL_IMAGE_PATH="/var/lib/zfs-${POOL_NAME}.img"
POOL_SIZE_MB=512

# Remote (EBS) mode — block device on the remote machine
POOL_DEVICE="${REMOTE_POOL_DEVICE:-}"

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
# Remote mode: ensure our current IP is allowed in the security group before
# attempting any SSH connections. Silently skips if AWS_SG_ID is not set or
# the AWS CLI is not available.
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "remote" ]]; then
    ensure_sg_allows_current_ip
fi

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

    # Ubuntu 24.04 uses ssh.socket (systemd socket activation) by default.
    # Under socket activation a new sshd process is spawned per connection,
    # which means during heavy work (apt-get, cargo build, etc.) the socket
    # can hit its backlog limit and silently drop new TCP connections — this
    # looks exactly like a timeout from the outside.  Switch to a traditional
    # persistent sshd daemon before doing anything else so all subsequent SSH
    # calls are reliable.
    log "Switching sshd to persistent daemon mode (disabling socket activation) ..."
    remote_exec_sudo "
        # Only do this once — if ssh.service is already enabled and running
        # as a persistent daemon, socket activation is already disabled.
        if systemctl is-enabled ssh.socket &>/dev/null; then
            systemctl disable --now ssh.socket   2>/dev/null || true
            systemctl enable  --now ssh.service  2>/dev/null || true
            echo 'sshd switched to persistent daemon mode.'
        else
            echo 'sshd already running as persistent daemon — skipping.'
        fi
    "
    ok "sshd is running as a persistent daemon."

    # Ensure the work directory exists on the remote
    log "Ensuring work directory '${WORK_DIR}' exists on remote ..."
    remote_exec_sudo "mkdir -p '${WORK_DIR}'"

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

    PKGS='zfsutils-linux curl git rsync'

    # Only pull in zfs-dkms if the kernel doesn't already ship zfs.ko
    if ! modinfo zfs &>/dev/null; then
        PKGS=\"\${PKGS} zfs-dkms\"
    fi

    # Skip apt round-trip when every package is already installed
    if dpkg -s \${PKGS} &>/dev/null 2>&1; then
        echo 'All packages already installed — skipping.'
    else
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends \${PKGS} 2>&1 | tail -5
    fi
"
ok "System packages installed."

# ---------------------------------------------------------------------------
# Step: Create worker user (both modes)
# ---------------------------------------------------------------------------
log "Creating '${WORKER_USER}' user ..."

remote_exec_sudo "
    if id '${WORKER_USER}' &>/dev/null; then
        echo 'User ${WORKER_USER} already exists — skipping.'
    else
        useradd -r -m -s /bin/bash '${WORKER_USER}'
        echo 'User ${WORKER_USER} created.'
    fi

    # Ensure work directory exists and is owned by worker
    mkdir -p '${WORK_DIR}'
    chown -R '${WORKER_USER}:${WORKER_USER}' '${WORK_DIR}'
"
ok "User '${WORKER_USER}' ready."

# ---------------------------------------------------------------------------
# Step: Go toolchain (both modes)
# ---------------------------------------------------------------------------
log "Installing Go toolchain ..."

remote_exec_sudo "
    if /usr/local/go/bin/go version &>/dev/null; then
        echo \"Go already installed: \$(/usr/local/go/bin/go version)\"
    else
        GO_VERSION=1.23.6
        ARCH=\$(dpkg --print-architecture)
        case \"\$ARCH\" in
            amd64)  GO_ARCH=amd64 ;;
            arm64)  GO_ARCH=arm64 ;;
            *)      echo \"Unsupported arch: \$ARCH\"; exit 1 ;;
        esac
        curl -fsSL \"https://go.dev/dl/go\${GO_VERSION}.linux-\${GO_ARCH}.tar.gz\" \
            | tar -C /usr/local -xz
        echo \"Go \${GO_VERSION} installed.\"
    fi

    # Ensure worker user has Go on PATH
    if ! grep -q '/usr/local/go/bin' /home/${WORKER_USER}/.profile 2>/dev/null; then
        echo 'export PATH=\$PATH:/usr/local/go/bin' >> /home/${WORKER_USER}/.profile
        echo 'export PATH=\$PATH:/usr/local/go/bin' >> /home/${WORKER_USER}/.bashrc
    fi
"
ok "Go toolchain ready."

# ---------------------------------------------------------------------------
# Step: ZFS pool setup
# ---------------------------------------------------------------------------
log "Setting up ZFS pool '${POOL_NAME}' ..."

if [[ "${MODE}" == "remote" ]]; then
    # -----------------------------------------------------------------------
    # Remote: create pool directly on the EBS block device.
    # ZFS owns the raw device — no image file, no loopback, no extra service.
    # -----------------------------------------------------------------------
    remote_exec_sudo "
        set -euo pipefail

        # Load the ZFS kernel module if not already loaded
        if ! lsmod | grep -q '^zfs'; then
            modprobe zfs
        fi

        # Idempotent: skip if pool already imported
        if zpool list '${POOL_NAME}' &>/dev/null; then
            echo 'Pool already exists — skipping creation.'
            zpool status '${POOL_NAME}'
            exit 0
        fi

        # Verify the block device exists
        if [[ ! -b '${POOL_DEVICE}' ]]; then
            echo \"ERROR: block device '${POOL_DEVICE}' not found.\" >&2
            echo 'Available block devices:' >&2
            lsblk -o NAME,SIZE,TYPE,MOUNTPOINT >&2
            exit 1
        fi

        zpool create -f '${POOL_NAME}' '${POOL_DEVICE}'
        zpool status '${POOL_NAME}'
        echo 'ZFS pool created successfully on ${POOL_DEVICE}.'
    "
    ok "ZFS pool '${POOL_NAME}' is ready on ${POOL_DEVICE}."

    # Grant worker user full ZFS permissions on the pool
    log "Granting ZFS permissions to '${WORKER_USER}' on '${POOL_NAME}' ..."
    remote_exec_sudo "
        zfs allow -u '${WORKER_USER}' clone,create,destroy,mount,snapshot,rollback,send,receive,hold,release,refreservation '${POOL_NAME}'
        echo 'ZFS permissions granted.'
        zfs allow '${POOL_NAME}'
    "
    ok "ZFS permissions granted to '${WORKER_USER}'."

    # -----------------------------------------------------------------------
    # Remote: enable the standard ZFS import services so the pool is
    # automatically imported after a reboot.  No loopback service needed.
    # -----------------------------------------------------------------------
    log "Enabling ZFS import services for automatic pool import on reboot ..."
    remote_exec_sudo "
        # Write the pool cachefile so zfs-import-cache can find it on boot
        zpool set cachefile=/etc/zfs/zpool.cache '${POOL_NAME}' 2>/dev/null || true

        systemctl enable zfs-import-cache.service  2>/dev/null || true
        systemctl enable zfs-import.target          2>/dev/null || true
        systemctl enable zfs-mount.service          2>/dev/null || true
        systemctl enable zfs.target                 2>/dev/null || true
        echo 'ZFS boot services enabled.'
    "
    ok "ZFS boot services enabled — pool will auto-import on reboot."

else
    # -----------------------------------------------------------------------
    # Local (Multipass): create pool on a loopback-backed image file.
    # -----------------------------------------------------------------------
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

    # Grant worker user full ZFS permissions on the pool
    log "Granting ZFS permissions to '${WORKER_USER}' on '${POOL_NAME}' ..."
    remote_exec_sudo "
        zfs allow -u '${WORKER_USER}' clone,create,destroy,mount,snapshot,rollback,send,receive,hold,release,refreservation '${POOL_NAME}'
        echo 'ZFS permissions granted.'
        zfs allow '${POOL_NAME}'
    "
    ok "ZFS permissions granted to '${WORKER_USER}'."

    # -----------------------------------------------------------------------
    # Local: install the loopback persistence service so the pool survives
    # VM reboots (the loop device must be re-attached before zfs-import runs).
    # -----------------------------------------------------------------------
    log "Installing loopback pool persistence service ..."
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
        echo 'Loopback pool persistence service installed.'
    "
    ok "Loopback pool persistence service installed."
fi

# ---------------------------------------------------------------------------
# Step: Pre-formatted base volume for zvol branches
# ---------------------------------------------------------------------------
log "Setting up pre-formatted base volume '${POOL_NAME}/_base/vol@empty' ..."

remote_exec_sudo "
    set -euo pipefail

    # Skip if the snapshot already exists
    if zfs list -H '${POOL_NAME}/_base/vol@empty' &>/dev/null; then
        echo 'Base snapshot already exists — skipping.'
        exit 0
    fi

    # Create the _base parent dataset
    if ! zfs list -H '${POOL_NAME}/_base' &>/dev/null; then
        zfs create '${POOL_NAME}/_base'
    fi

    # Create a thin 1 GiB zvol
    if ! zfs list -H '${POOL_NAME}/_base/vol' &>/dev/null; then
        zfs create -V 1073741824 -o refreservation=none '${POOL_NAME}/_base/vol'
    fi

    # Wait for the block device to appear
    DEVICE='/dev/zvol/${POOL_NAME}/_base/vol'
    for i in \$(seq 1 50); do
        [ -b \"\${DEVICE}\" ] && break
        sleep 0.2
    done
    if [ ! -b \"\${DEVICE}\" ]; then
        echo \"ERROR: block device \${DEVICE} did not appear\" >&2
        exit 1
    fi

    # Format with ext4
    mkfs.ext4 -F -L '_base/vol' -E lazy_itable_init=0,lazy_journal_init=0 \"\${DEVICE}\"

    # Snapshot — this is the permanent base for all zvol branches
    zfs snapshot '${POOL_NAME}/_base/vol@empty'
    echo 'Base volume created and snapshotted.'
"
ok "Base volume '${POOL_NAME}/_base/vol@empty' is ready."

# ---------------------------------------------------------------------------
# Step: Worker systemd service (both modes)
# ---------------------------------------------------------------------------
log "Installing worker systemd service unit ..."

# Remote mode: pool is managed by standard ZFS boot services — no loopback dep.
# Local mode:  pool needs the loopback service to re-attach the image on boot.
if [[ "${MODE}" == "remote" ]]; then
    _SVC_AFTER="network.target zfs-import.target"
    _SVC_WANTS=""
else
    _SVC_AFTER="network.target zfs-import.target zfs-loopback-pool.service"
    _SVC_WANTS="Wants=zfs-loopback-pool.service"
fi

remote_exec_sudo "
cat > /etc/systemd/system/fs-worker.service <<'UNIT'
[Unit]
Description=fs-worker Temporal activity worker
After=${_SVC_AFTER}
${_SVC_WANTS}

[Service]
Type=simple
User=${WORKER_USER}
WorkingDirectory=${WORK_DIR}
Environment=ZFS_POOL=${POOL_NAME}
ExecStart=${WORK_DIR}/fs-worker
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
