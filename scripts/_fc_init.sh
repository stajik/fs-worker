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
#   Prints a readiness marker and blocks reading from the serial console.
#   The host pauses+snapshots the VM while it blocks on read.
#   After snapshot restore, the host writes the command to FC stdin.
#   Boot args example:
#     init=/_fc_init.sh fc_nodata=1

# Minimal early mounts.
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run

# Mount the data drive at /data unless fc_nodata=1 is set.
FC_NODATA=$(cat /proc/cmdline | tr " " "\n" | grep "^fc_nodata=" | sed "s/fc_nodata=//")
if [ "$FC_NODATA" != "1" ]; then
    mkdir -p /data
    mount -t ext4 /dev/vdb /data
    if ! mountpoint -q /data; then
        echo "Failed to mount /data" >&2
        reboot -f
    fi
fi

echo "===FC_READY==="

# Extract fc_cmd from kernel command line.
FC_CMD=$(cat /proc/cmdline | tr " " "\n" | grep "^fc_cmd=" | sed "s/fc_cmd=//")

if [ -n "$FC_CMD" ]; then
    # === COLD MODE: command in boot args ===
    CMD=$(echo "$FC_CMD" | base64 -d)
else
    # === SNAPSHOT MODE: command delivery via serial console ===
    # The host will pause+snapshot while we block on read.
    # After restore, the host writes the base64-encoded command to stdin.
    read -r CMD_B64 < /dev/ttyS0
    CMD=$(echo "$CMD_B64" | base64 -d)
fi

if mountpoint -q /data 2>/dev/null; then
    cd /data
fi

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
