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

	logger.Info("Exec: starting",
		"id", input.ID,
		"mode", input.Mode,
		"template_id", input.TemplateID,
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
	if input.UseSnapshot {
		stdout, stderr, exitCode, rawStdout, rawStderr, vmErr = runFromSnapshot(vmCtx, input.ID, input.TemplateID, drivePath, input.Cmd)
	} else {
		stdout, stderr, exitCode, rawStdout, rawStderr, vmErr = runFromTemplate(vmCtx, input.ID, input.TemplateID, drivePath, input.Cmd)
	}

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
			logger.Warn("Exec: VM timed out, returning partial output",
				"id", input.ID,
				"vm_error", vmErr,
			)
			return ExecOutput{
				ExitCode: -1,
				Stdout:   stdout,
				Stderr:   stderr,
				TimedOut: true,
			}, nil
		}
		return ExecOutput{}, fmt.Errorf("run firecracker: %w", vmErr)
	}

	logger.Info("Exec: done",
		"id", input.ID,
		"exit_code", exitCode,
	)

	return ExecOutput{
		ExitCode: exitCode,
		Stdout:   stdout,
		Stderr:   stderr,
	}, nil
}
