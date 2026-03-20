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
#   After mounts and cmdline parsing, prints ===FC_READY=== and enters a
#   poll loop on /dev/vdc. The host pauses+snapshots during this loop.
#   After restore the cmd drive has the real command; drop_caches ensures
#   we bypass the stale page cache from the snapshot memory.
#   Boot args example:
#     init=/_fc_init.sh fc_nodata=1

# Minimal early mounts (ignore already-mounted errors).
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sys /sys 2>/dev/null
mount -t devtmpfs dev /dev 2>/dev/null
mount -t tmpfs tmpfs /tmp 2>/dev/null
mount -t tmpfs tmpfs /run 2>/dev/null

# Parse kernel command line BEFORE the ready marker so that all fork-heavy
# work (pipelines, subshells) is done before the snapshot point. This way
# the snapshot captures the VM in a clean state inside the poll loop.
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

echo "===FC_READY==="

if [ -n "$FC_CMD" ]; then
    # === COLD MODE: command in boot args ===
    echo "[fc_init] cold mode"
    CMD=$(echo "$FC_CMD" | base64 -d)
else
    # === SNAPSHOT MODE: command delivery via block device ===
    # The host pauses+snapshots the VM while this loop spins.
    # During capture /dev/vdc is a zero-filled placeholder so the loop
    # keeps iterating. After restore the host swaps in a real cmd drive;
    # drop_caches evicts only the stale /dev/vdc pages.
    # Poll /dev/vdc using only shell builtins — no fork/exec in the loop.
    # This is critical because the host snapshots the VM while this loop
    # runs. If child processes (dd, tr, etc.) are in-flight at snapshot
    # time, they hang on restore.
    # `read` on the zero-filled placeholder returns empty (nulls are
    # dropped by the shell). On the real cmd drive it returns the base64
    # command (up to the newline).
    echo "[fc_init] snapshot mode: polling /dev/vdc"
    ITER=0
    while true; do
        ITER=$((ITER + 1))
        echo 1 > /proc/sys/vm/drop_caches 2>/dev/null
        CMD_B64=""
        read -r CMD_B64 < /dev/vdc 2>/dev/null || true
        echo "[fc_init] poll #${ITER}: len=${#CMD_B64}"
        [ -n "$CMD_B64" ] && break
    done
    echo "[fc_init] got command after ${ITER} poll(s)"
    CMD=$(echo "$CMD_B64" | base64 -d)
fi

echo "[fc_init] CMD=[$(echo "$CMD" | head -c 200)]"

if mountpoint -q /data 2>/dev/null; then
    cd /data
fi

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

sync
reboot -f
