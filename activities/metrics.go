package activities

import (
	"regexp"
	"strconv"
	"time"

	"go.temporal.io/sdk/client"
)

const (
	metricInitBranchDuration = "fs_init_branch_duration"
	metricExecDuration       = "fs_exec_duration"
	metricVMKernelBoot       = "fs_vm_kernel_boot_duration"
	metricVMGuestInit        = "fs_vm_guest_init_duration"
	metricCmdDuration        = "fs_cmd_duration"
	metricVMSyncDuration     = "fs_vm_sync_duration"
	metricVMTotalDuration    = "fs_vm_total_duration"
	metricVMShutdownDuration = "fs_vm_shutdown_duration"
	metricSnapshotDuration   = "fs_snapshot_duration"
	metricS3UploadDuration   = "fs_s3_upload_duration"
	metricS3UploadBytes      = "fs_s3_upload_bytes"
)

var (
	reBootT0   = regexp.MustCompile(`===FC_BOOT_T0=(\d+)===`)
	reBootTime = regexp.MustCompile(`===FC_BOOT_TIME=(\d+)===`)
	reCmdTime  = regexp.MustCompile(`===FC_TIME=(\d+)===`)
	reSyncTime = regexp.MustCompile(`===FC_SYNC_TIME=(\d+)===`)
)

// recordVMMetrics parses timing markers from the raw VM stdout and records
// them via the Temporal SDK metrics handler.
//
// Markers:
//
//	===FC_BOOT_T0=<unix_ms>===    — guest epoch ms when init script started
//	===FC_BOOT_TIME=<ms>===       — guest-side init duration (BOOT_T0 to cmd start)
//	===FC_TIME=<ms>===            — command execution duration inside the guest
//
// metricsHandler is the SDK metrics handler obtained from activity context.
// vmStart is the host-side timestamp taken just before startFirecracker.
// totalVMDuration is the host-side wall clock time from vmStart to
// machine.Wait returning.
func recordVMMetrics(handler client.MetricsHandler, rawStdout string, vmStart time.Time, totalVMDuration time.Duration) {
	handler.Timer(metricVMTotalDuration).Record(totalVMDuration)

	var kernelMs, initMs, cmdMs, syncMs float64

	// Kernel boot: host vmStart → guest BOOT_T0.
	if m := reBootT0.FindStringSubmatch(rawStdout); len(m) == 2 {
		if guestT0, err := strconv.ParseInt(m[1], 10, 64); err == nil {
			hostStartMs := vmStart.UnixMilli()
			kernelMs = float64(guestT0 - hostStartMs)
			if kernelMs >= 0 {
				handler.Timer(metricVMKernelBoot).Record(time.Duration(kernelMs) * time.Millisecond)
			}
		}
	}

	// Guest init: BOOT_T0 → command execution start.
	if m := reBootTime.FindStringSubmatch(rawStdout); len(m) == 2 {
		if v, err := strconv.ParseFloat(m[1], 64); err == nil {
			initMs = v
			handler.Timer(metricVMGuestInit).Record(time.Duration(v) * time.Millisecond)
		}
	}

	// Command execution.
	if m := reCmdTime.FindStringSubmatch(rawStdout); len(m) == 2 {
		if v, err := strconv.ParseFloat(m[1], 64); err == nil {
			cmdMs = v
			handler.Timer(metricCmdDuration).Record(time.Duration(v) * time.Millisecond)
		}
	}

	// Sync (fsync at end of _fc_init.sh).
	if m := reSyncTime.FindStringSubmatch(rawStdout); len(m) == 2 {
		if v, err := strconv.ParseFloat(m[1], 64); err == nil {
			syncMs = v
			handler.Timer(metricVMSyncDuration).Record(time.Duration(v) * time.Millisecond)
		}
	}

	// Shutdown: total - kernel_boot - guest_init - cmd - sync.
	if kernelMs > 0 || initMs > 0 || cmdMs > 0 || syncMs > 0 {
		shutdownMs := float64(totalVMDuration.Milliseconds()) - kernelMs - initMs - cmdMs - syncMs
		if shutdownMs >= 0 {
			handler.Timer(metricVMShutdownDuration).Record(time.Duration(shutdownMs) * time.Millisecond)
		}
	}
}
