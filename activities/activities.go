package activities

import (
	"context"
	"fmt"

	"go.temporal.io/sdk/activity"
)

// FsWorkerActivities holds shared state for the activity worker.
type FsWorkerActivities struct {
	pool string
}

// NewFsWorkerActivities returns a ready-to-use FsWorkerActivities for the
// given ZFS pool.
func NewFsWorkerActivities(pool string) *FsWorkerActivities {
	return &FsWorkerActivities{pool: pool}
}

// InitBranch creates a new branch as either a ZFS zvol (block device) or a
// ZFS dataset (filesystem), depending on the requested mode.
//
// For zvol mode the branch is created by cloning the pre-formatted base
// snapshot (<pool>/_base/vol@empty) that was set up at worker startup.
//
// For zds mode a plain ZFS filesystem dataset is created.
func (a *FsWorkerActivities) InitBranch(ctx context.Context, input InitBranchInput) error {
	logger := activity.GetLogger(ctx)

	if err := validateID(input.ID); err != nil {
		return fmt.Errorf("invalid id: %w", err)
	}
	if err := validateMode(input.Mode); err != nil {
		return err
	}

	dataset := datasetName(a.pool, input.ID)

	logger.Info("InitBranch: starting", "id", input.ID, "mode", input.Mode, "dataset", dataset)

	switch input.Mode {
	case BranchModeZvol:
		snap := baseSnapshotFull(a.pool)
		if err := cloneSnapshot(snap, dataset); err != nil {
			return fmt.Errorf("clone %q -> %q: %w", snap, dataset, err)
		}

		device := zvolDevicePath(dataset)
		if err := waitForDevice(ctx, device); err != nil {
			return fmt.Errorf("wait for device %q: %w", device, err)
		}

		logger.Info("InitBranch: done (zvol)", "dataset", dataset, "device", device)
		return nil

	case BranchModeZDS:
		if err := createDataset(dataset); err != nil {
			return fmt.Errorf("create dataset %q: %w", dataset, err)
		}

		logger.Info("InitBranch: done (zds)", "dataset", dataset)
		return nil

	default:
		// validateMode already rejects unknown modes, but the compiler needs this.
		return fmt.Errorf("unsupported mode %q", input.Mode)
	}
}
