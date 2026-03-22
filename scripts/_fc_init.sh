#!/bin/sh
# _fc_init.sh — Firecracker microVM init script (PID 1)
#
# Baked into the ext4 rootfs at /_fc_init.sh during setup.
#
# Two modes of operation:
#
# Cold mode (fc_cmd in boot args):
#   The command is base64-encoded in the kernel boot arg fc_cmd=<base64>.
#   Boot args example:
#     init=/_fc_init.sh fc_cmd=ZWNobyBoZWxsbw==
#
# Snapshot mode (no fc_cmd in boot args):
#   Starts /_fc_agent (vsock listener on port 52000), waits 200ms for it to
#   reach Accept(), then prints ===FC_READY===.  The host pauses+snapshots
#   the VM while _fc_agent is blocked in Accept().  On restore the host
#   connects via the Firecracker vsock UDS proxy, sends the base64 command,
#   and _fc_agent writes it to /tmp/fc_cmd_b64 and exits.
#   Boot args example:
#     init=/_fc_init.sh fc_nodata=1

# Capture boot start time as early as possible (Unix epoch milliseconds).
BOOT_T0=$(date +%s%3N)
echo "===FC_BOOT_T0=$BOOT_T0==="

# Minimal early mounts (ignore already-mounted errors).
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sys /sys 2>/dev/null
mount -t devtmpfs dev /dev 2>/dev/null
mount -t tmpfs tmpfs /tmp 2>/dev/null
mount -t tmpfs tmpfs /run 2>/dev/null

# Parse kernel command line before any snapshot-related work so all
# fork-heavy pipelines finish before the snapshot point.
FC_NODATA=""
FC_CMD=""
for word in $(cat /proc/cmdline); do
    case "$word" in
        fc_nodata=*) FC_NODATA="${word#fc_nodata=}" ;;
        fc_cmd=*)    FC_CMD="${word#fc_cmd=}" ;;
    esac
done

# Mount the data drive at /data unless fc_nodata=1 is set.
if [ "$FC_NODATA" != "1" ]; then
    mkdir -p /data
    mount -t ext4 /dev/vdb /data
    if ! mountpoint -q /data; then
        echo "Failed to mount /data" >&2
        reboot -f
    fi
fi

if [ -n "$FC_CMD" ]; then
    # === COLD MODE: command in boot args ===
    # ===FC_READY=== is not used by cold-boot callers but harmless to emit.
    echo "===FC_READY==="
    echo "[fc_init] cold mode"
    CMD=$(echo "$FC_CMD" | base64 -d)
else
    # === SNAPSHOT MODE: command delivery via vsock ===
    # Load the virtio vsock kernel module (may be built-in; errors are OK).
    modprobe vsock 2>/dev/null || true
    modprobe vmw_vsock_virtio_transport 2>/dev/null || true

    # Start the vsock agent listener in the background.  It binds and
    # listens on vsock port 52000, then blocks in Accept() waiting for the
    # host to connect after snapshot restore.
    echo "[fc_init] snapshot mode: starting vsock agent"
    /_fc_agent > /tmp/fc_cmd_b64 &
    FC_AGENT_PID=$!

    # Give the agent enough time to reach Accept() before we print the
    # ready marker and the host captures the snapshot.
    sleep 0.2

    echo "===FC_READY==="

    # Host pauses + snapshots the VM while _fc_agent is blocked in Accept().
    # On restore the host connects, sends the base64 command, and the agent
    # writes it to /tmp/fc_cmd_b64 and exits.
    wait $FC_AGENT_PID
    CMD_B64=$(cat /tmp/fc_cmd_b64)
    echo "[fc_init] got command via vsock"
    CMD=$(echo "$CMD_B64" | base64 -d)
fi

echo "[fc_init] CMD=[$(echo "$CMD" | head -c 200)]"

if mountpoint -q /data 2>/dev/null; then
    cd /data
fi

BOOT_T1=$(date +%s%3N)
BOOT_ELAPSED=$((BOOT_T1 - BOOT_T0))
echo "===FC_BOOT_TIME=$BOOT_ELAPSED==="

echo "[fc_init] executing command"
T0=$(date +%s%3N)
(eval "$CMD") > /tmp/fc_stdout 2>/tmp/fc_stderr
RC=$?
T1=$(date +%s%3N)
ELAPSED=$((T1 - T0))

echo "===FC_STDOUT_START==="
cat /tmp/fc_stdout
echo "===FC_STDOUT_END==="
echo "===FC_STDERR_START==="
cat /tmp/fc_stderr
echo "===FC_STDERR_END==="
echo "===FC_EXIT_CODE=$RC==="
echo "===FC_TIME=$ELAPSED==="

SYNC_T0=$(date +%s%3N)
sync
SYNC_T1=$(date +%s%3N)
SYNC_ELAPSED=$((SYNC_T1 - SYNC_T0))
echo "===FC_SYNC_TIME=$SYNC_ELAPSED==="

reboot -f
