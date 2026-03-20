package activities

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

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

		// Pre-create the mountpoint directory so sudo zfs mount succeeds.
		mp := datasetMountPoint(a.pool, input.ID)
		if err := os.MkdirAll(mp, 0755); err != nil {
			return fmt.Errorf("create mountpoint %q: %w", mp, err)
		}

		// zfs mount requires root on Linux; worker has narrow sudo for this.
		if err := mountDataset(dataset); err != nil {
			return fmt.Errorf("mount dataset %q: %w", dataset, err)
		}

		// Copy the pre-formatted base data image into the dataset.
		dst := filepath.Join(mp, dataImgName)
		if err := copyFile(baseDataImgPath, dst); err != nil {
			return fmt.Errorf("copy base data image to %q: %w", dst, err)
		}

		logger.Info("InitBranch: done (zds)", "dataset", dataset, "mountpoint", mp)
		return nil

	default:
		// validateMode already rejects unknown modes, but the compiler needs this.
		return fmt.Errorf("unsupported mode %q", input.Mode)
	}
}

// copyFile copies src to dst preserving sparseness via cp --sparse=always.
func copyFile(src, dst string) error {
	out, err := exec.Command("cp", "--sparse=always", src, dst).CombinedOutput()
	if err != nil {
		return fmt.Errorf("cp --sparse=always %q %q: %s", src, dst, strings.TrimSpace(string(out)))
	}
	return nil
}
