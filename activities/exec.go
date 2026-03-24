package activities

import (
	"context"
	"fmt"
	"time"

	"go.temporal.io/sdk/activity"
	"go.temporal.io/sdk/client"
)

const (
	// vmGracePeriod is the time reserved before the activity deadline for
	// cleanup and returning the VM output. The VM gets a context that expires
	// this much earlier than the activity context.
	vmGracePeriod = 5 * time.Second
)

// Exec restores a Firecracker microVM from a template snapshot, attaches the
// branch's data drive, and delivers the command via the serial console.
//
// The VM was snapshotted while blocked on `read -r CMD_B64 < /dev/ttyS0`;
// so upon restore it immediately reads the base64-encoded command from stdin,
// executes it, prints structured output markers, and reboots.
//
// To ensure partial output is returned even when the activity is about to
// time out, the VM runs under a shortened context that expires vmGracePeriod
// before the activity deadline.
func (a *FsWorkerActivities) Exec(ctx context.Context, input ExecInput) (ExecOutput, error) {
	t0 := time.Now()
	metricsHandler := activity.GetMetricsHandler(ctx).WithTags(map[string]string{"mode": string(input.Mode)})
	defer func() {
		metricsHandler.Timer(metricExecDuration).Record(time.Since(t0))
	}()

	logger := activity.GetLogger(ctx)

	if err := validateID(input.ID); err != nil {
		return ExecOutput{}, fmt.Errorf("invalid id: %w", err)
	}
	if err := validateMode(input.Mode); err != nil {
		return ExecOutput{}, err
	}
	if input.TemplateID == "" {
		return ExecOutput{}, fmt.Errorf("template_id must not be empty")
	}
	if input.Cmd == "" {
		return ExecOutput{}, fmt.Errorf("cmd must not be empty")
	}
	if input.TargetSnapshot == "" {
		return ExecOutput{}, fmt.Errorf("target_snapshot must not be empty")
	}
	if input.BaseSnapshot == "" {
		return ExecOutput{}, fmt.Errorf("base_snapshot must not be empty")
	}

	dataset := datasetName(a.pool, input.ID)

	// Idempotency: if the target snapshot already exists, the exec already
	// completed successfully. Ensure the branch is on the target and return.
	if err := rollbackToSnapshot(dataset, input.TargetSnapshot); err == nil {
		logger.Info("Exec: target snapshot already exists, skipping execution",
			"dataset", dataset, "target_snapshot", input.TargetSnapshot)
		return ExecOutput{}, nil
	}

	// When base_snapshot is __init, create a new branch first. Otherwise
	// roll the existing branch back to the requested base snapshot.
	if input.BaseSnapshot == initSnapshotName {
		if err := a.InitBranch(ctx, InitBranchInput{
			ID:   input.ID,
			Mode: input.Mode,
		}); err != nil {
			return ExecOutput{}, fmt.Errorf("init branch %q: %w", input.ID, err)
		}
	} else {
		if err := rollbackToSnapshot(dataset, input.BaseSnapshot); err != nil {
			if input.Reconstruct == nil {
				return ExecOutput{}, fmt.Errorf("rollback %q to @%s: %w", dataset, input.BaseSnapshot, err)
			}
			logger.Info("Exec: rollback failed, attempting reconstruction from S3",
				"id", input.ID,
				"base_snapshot", input.BaseSnapshot,
				"snapshots", input.Reconstruct.Snapshots,
				"rollback_error", err,
			)
			if err := a.reconstructBranch(ctx, input, metricsHandler); err != nil {
				return ExecOutput{}, fmt.Errorf("reconstruct branch %q: %w", input.ID, err)
			}
			switch input.Mode {
			case BranchModeZvol:
				if err := waitForDevice(ctx, zvolDevicePath(dataset)); err != nil {
					return ExecOutput{}, fmt.Errorf("wait for zvol device after reconstruction: %w", err)
				}
			case BranchModeZDS:
				if err := mountDataset(dataset); err != nil {
					return ExecOutput{}, fmt.Errorf("mount dataset after reconstruction: %w", err)
				}
			}
		}
	}

	logger.Info("Exec: starting",
		"id", input.ID,
		"mode", input.Mode,
		"template_id", input.TemplateID,
		"base_snapshot", input.BaseSnapshot,
		"use_snapshot", input.UseSnapshot,
		"cmd", input.Cmd,
	)

	// Resolve the block device or image path for this branch.
	drivePath, err := resolveDrivePath(a.pool, input.ID, input.Mode)
	if err != nil {
		return ExecOutput{}, fmt.Errorf("resolve drive path: %w", err)
	}

	// Derive a VM context that expires before the activity deadline so we
	// have time to return whatever output was captured.
	vmCtx := ctx
	if deadline, ok := ctx.Deadline(); ok {
		remaining := time.Until(deadline)
		if remaining > vmGracePeriod {
			var cancel context.CancelFunc
			vmCtx, cancel = context.WithDeadline(ctx, deadline.Add(-vmGracePeriod))
			defer cancel()
		}
	}

	var stdout, stderr, rawStdout, rawStderr string
	var exitCode int
	var vmErr error
	vmStart := time.Now()
	if input.UseSnapshot {
		stdout, stderr, exitCode, rawStdout, rawStderr, vmErr = runFromSnapshot(vmCtx, input.ID, input.TemplateID, drivePath, input.Cmd)
	} else {
		stdout, stderr, exitCode, rawStdout, rawStderr, vmErr = runFromTemplate(vmCtx, input.ID, input.TemplateID, drivePath, input.Cmd)
	}
	vmDuration := time.Since(vmStart)

	recordVMMetrics(metricsHandler, rawStdout, vmStart, vmDuration)

	logger.Debug("Exec: VM raw output",
		"id", input.ID,
		"raw_stdout", rawStdout,
		"raw_stderr", rawStderr,
	)

	if vmErr != nil {
		// If the VM context timed out but the activity context is still alive,
		// return the partial output as a successful (but timed-out) result
		// instead of propagating the error.
		if vmCtx.Err() != nil && ctx.Err() == nil {
			logger.Warn("Exec: VM timed out, rolling back to base snapshot",
				"id", input.ID,
				"vm_error", vmErr,
			)
			if rbErr := rollbackToSnapshot(dataset, input.BaseSnapshot); rbErr != nil {
				logger.Error("Exec: rollback after timeout failed", "error", rbErr)
			}
			return ExecOutput{
				ExitCode: -1,
				Stdout:   stdout,
				Stderr:   stderr,
				TimedOut: true,
			}, nil
		}
		// Roll back to base on VM error.
		if rbErr := rollbackToSnapshot(dataset, input.BaseSnapshot); rbErr != nil {
			logger.Error("Exec: rollback after VM error failed", "error", rbErr)
		}
		return ExecOutput{}, fmt.Errorf("run firecracker: %w", vmErr)
	}

	// Non-zero exit code: rollback to base snapshot.
	if exitCode != 0 {
		logger.Info("Exec: command failed, rolling back to base snapshot",
			"id", input.ID, "exit_code", exitCode)
		if rbErr := rollbackToSnapshot(dataset, input.BaseSnapshot); rbErr != nil {
			logger.Error("Exec: rollback after failed command failed", "error", rbErr)
		}
		return ExecOutput{
			ExitCode: exitCode,
			Stdout:   stdout,
			Stderr:   stderr,
		}, nil
	}

	// Success: create the target snapshot.
	snapStart := time.Now()
	if err := createSnapshot(dataset, input.TargetSnapshot); err != nil {
		return ExecOutput{}, fmt.Errorf("create target snapshot @%s for %q: %w",
			input.TargetSnapshot, dataset, err)
	}
	metricsHandler.Timer(metricSnapshotDuration).Record(time.Since(snapStart))

	// Upload incremental diff to S3 (including __init → first snapshot).
	uploadStart := time.Now()
	uploadBytes, err := a.uploadSnapshotDiff(ctx, dataset, input.ID, input.BaseSnapshot, input.TargetSnapshot)
	if err != nil {
		logger.Error("Exec: failed to upload snapshot diff to S3",
			"id", input.ID,
			"base_snapshot", input.BaseSnapshot,
			"target_snapshot", input.TargetSnapshot,
			"error", err,
		)
		return ExecOutput{}, fmt.Errorf("upload snapshot diff to S3: %w", err)
	}
	metricsHandler.Timer(metricS3UploadDuration).Record(time.Since(uploadStart))
	a.s3UploadBytesHist.Observe(float64(uploadBytes))
	logger.Info("Exec: uploaded snapshot diff to S3",
		"id", input.ID,
		"key", input.ID+"/"+input.TargetSnapshot,
		"bytes", uploadBytes,
	)

	logger.Info("Exec: done",
		"id", input.ID,
		"exit_code", exitCode,
		"target_snapshot", input.TargetSnapshot,
	)

	return ExecOutput{
		ExitCode: exitCode,
		Stdout:   stdout,
		Stderr:   stderr,
	}, nil
}

// reconstructBranch rebuilds a branch from scratch using diffs stored in S3.
// It creates the branch (via InitBranch), then prefetches the incremental
// diffs in parallel (up to maxPrefetchConcurrency) and applies them
// sequentially via `zfs receive`.
//
// Metrics recorded:
//   - fs_s3_download_duration  — per-blob download latency
//   - fs_s3_download_bytes     — per-blob size histogram
//   - fs_reconstruction_duration — total wall-clock time for the full rebuild
func (a *FsWorkerActivities) reconstructBranch(ctx context.Context, input ExecInput, metricsHandler client.MetricsHandler) error {
	reconstructStart := time.Now()
	logger := activity.GetLogger(ctx)
	dataset := datasetName(a.pool, input.ID)

	// Step 1: Destroy any existing branch, then create a fresh one without
	// the @__init snapshot so that the first blob (a full ZFS stream) can
	// be received cleanly.
	if err := destroyDataset(dataset); err != nil {
		return fmt.Errorf("destroy existing branch %q before reconstruction: %w", dataset, err)
	}
	if err := a.InitBranch(ctx, InitBranchInput{
		ID:               input.ID,
		Mode:             input.Mode,
		SkipInitSnapshot: true,
	}); err != nil {
		return fmt.Errorf("init branch: %w", err)
	}

	// Step 2: Determine which snapshots to reconstruct.
	// Collect all snapshots up to and including the base snapshot.
	var toFetch []string
	for _, snap := range input.Reconstruct.Snapshots {
		toFetch = append(toFetch, snap)
		if snap == input.BaseSnapshot {
			break
		}
	}

	if len(toFetch) == 0 {
		logger.Info("Exec: reconstruction — no diffs to fetch",
			"id", input.ID,
			"base_snapshot", input.BaseSnapshot,
		)
		metricsHandler.Timer(metricReconstructionDuration).Record(time.Since(reconstructStart))
		return nil
	}

	logger.Info("Exec: reconstructing — prefetching diffs from S3",
		"id", input.ID,
		"snapshots", toFetch,
		"count", len(toFetch),
	)

	// Step 3: Prefetch all diffs in parallel, then apply sequentially.
	// Per-blob download metrics are recorded inside prefetchSnapshotDiffs
	// via these callbacks.
	totalBytes, err := a.prefetchSnapshotDiffs(ctx, dataset, input.ID, toFetch,
		func(d time.Duration) { metricsHandler.Timer(metricS3DownloadDuration).Record(d) },
		func(b float64) { a.s3DownloadBytesHist.Observe(b) },
	)

	if err != nil {
		return fmt.Errorf("prefetch and apply diffs: %w", err)
	}

	logger.Info("Exec: reconstruction complete",
		"id", input.ID,
		"base_snapshot", input.BaseSnapshot,
		"diffs_applied", len(toFetch),
		"total_bytes", totalBytes,
	)

	metricsHandler.Timer(metricReconstructionDuration).Record(time.Since(reconstructStart))
	return nil
}
