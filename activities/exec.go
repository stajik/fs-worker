package activities

import (
	"context"
	"fmt"
	"time"

	"go.temporal.io/sdk/activity"
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
	metricsHandler := activity.GetMetricsHandler(ctx)
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
			return ExecOutput{}, fmt.Errorf("rollback %q to @%s: %w", dataset, input.BaseSnapshot, err)
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

	logger.Info("Exec: VM raw output",
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
	if err := createSnapshot(dataset, input.TargetSnapshot); err != nil {
		return ExecOutput{}, fmt.Errorf("create target snapshot @%s for %q: %w",
			input.TargetSnapshot, dataset, err)
	}

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
