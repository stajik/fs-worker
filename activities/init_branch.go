package activities

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"go.temporal.io/sdk/activity"
)

// FsWorkerActivities holds shared state for the activity worker.
type FsWorkerActivities struct {
	pool                string
	s3Bucket            string
	s3Region            string
	s3Client            *s3.Client
	s3UploadBytesHist   prometheus.Observer
	s3DownloadBytesHist prometheus.Observer
}

// s3UploadBytesHistogram is a Prometheus histogram registered once at
// package init time. Using promauto + prometheus directly (instead of tally)
// avoids the issue where tally's DefaultHistogramBuckets override the
// per-histogram buckets passed to scope.Histogram().
var s3UploadBytesHistogram = promauto.NewHistogram(prometheus.HistogramOpts{
	Name: "temporal_" + metricS3UploadBytes,
	Help: "Size of ZFS snapshot diffs uploaded to S3 in bytes.",
	Buckets: []float64{
		1024,               // 1 KB
		4 * 1024,           // 4 KB
		16 * 1024,          // 16 KB
		64 * 1024,          // 64 KB
		256 * 1024,         // 256 KB
		1024 * 1024,        // 1 MB
		4 * 1024 * 1024,    // 4 MB
		16 * 1024 * 1024,   // 16 MB
		64 * 1024 * 1024,   // 64 MB
		256 * 1024 * 1024,  // 256 MB
		1024 * 1024 * 1024, // 1 GB
	},
})

var s3DownloadBytesHistogram = promauto.NewHistogram(prometheus.HistogramOpts{
	Name: "temporal_" + metricS3DownloadBytes,
	Help: "Size of ZFS snapshot diffs downloaded from S3 in bytes.",
	Buckets: []float64{
		1024,               // 1 KB
		4 * 1024,           // 4 KB
		16 * 1024,          // 16 KB
		64 * 1024,          // 64 KB
		256 * 1024,         // 256 KB
		1024 * 1024,        // 1 MB
		4 * 1024 * 1024,    // 4 MB
		16 * 1024 * 1024,   // 16 MB
		64 * 1024 * 1024,   // 64 MB
		256 * 1024 * 1024,  // 256 MB
		1024 * 1024 * 1024, // 1 GB
	},
})

// NewFsWorkerActivities returns a ready-to-use FsWorkerActivities for the
// given ZFS pool.
func NewFsWorkerActivities(pool, s3Bucket, s3Region string) *FsWorkerActivities {
	return &FsWorkerActivities{
		pool:                pool,
		s3Bucket:            s3Bucket,
		s3Region:            s3Region,
		s3UploadBytesHist:   s3UploadBytesHistogram,
		s3DownloadBytesHist: s3DownloadBytesHistogram,
	}
}

// InitBranch creates a new branch as either a ZFS zvol (block device) or a
// ZFS dataset (filesystem), depending on the requested mode.
//
// The activity is idempotent: if the dataset already exists (e.g. from a
// previous partial run) the remaining setup steps are retried and the branch
// is rolled back to @__init before returning.
//
// For zvol mode the branch is created by cloning the pre-formatted base
// snapshot (<pool>/_base/vol@empty) that was set up at worker startup.
//
// For zds mode a plain ZFS filesystem dataset is created.
func (a *FsWorkerActivities) InitBranch(ctx context.Context, input InitBranchInput) error {
	t0 := time.Now()
	metricsHandler := activity.GetMetricsHandler(ctx).WithTags(map[string]string{"mode": string(input.Mode)})
	defer func() {
		metricsHandler.Timer(metricInitBranchDuration).Record(time.Since(t0))
	}()

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
		if input.SkipInitSnapshot {
			// Reconstruction: skip dataset creation entirely — the full
			// ZFS stream from S3 will create the dataset.
			logger.Info("InitBranch: skipping dataset creation for reconstruction (zvol)", "dataset", dataset)
			return nil
		}

		snap := baseSnapshotFull(a.pool)
		if err := cloneSnapshot(snap, dataset); err != nil {
			if !strings.Contains(err.Error(), "already exists") {
				return fmt.Errorf("clone %q -> %q: %w", snap, dataset, err)
			}
			logger.Info("InitBranch: dataset already exists, continuing setup", "dataset", dataset)
		}

		device := zvolDevicePath(dataset)
		if err := waitForDevice(ctx, device); err != nil {
			return fmt.Errorf("wait for device %q: %w", device, err)
		}

		if err := createSnapshot(dataset, initSnapshotName); err != nil {
			if !strings.Contains(err.Error(), "already exists") {
				return fmt.Errorf("create @%s snapshot for %q: %w", initSnapshotName, dataset, err)
			}
		}

		if err := rollbackToSnapshot(dataset, initSnapshotName); err != nil {
			return fmt.Errorf("rollback %q to @%s: %w", dataset, initSnapshotName, err)
		}

		logger.Info("InitBranch: done (zvol)", "dataset", dataset, "device", device)
		return nil

	case BranchModeZDS:
		if input.SkipInitSnapshot {
			// Reconstruction: only ensure the mountpoint directory exists.
			// The full ZFS stream from S3 will create the dataset.
			mp := datasetMountPoint(a.pool, input.ID)
			if err := os.MkdirAll(mp, 0755); err != nil {
				return fmt.Errorf("create mountpoint %q: %w", mp, err)
			}
			logger.Info("InitBranch: skipping dataset creation for reconstruction (zds)", "dataset", dataset, "mountpoint", mp)
			return nil
		}

		if err := createDataset(dataset); err != nil {
			if !strings.Contains(err.Error(), "already exists") {
				return fmt.Errorf("create dataset %q: %w", dataset, err)
			}
			logger.Info("InitBranch: dataset already exists, continuing setup", "dataset", dataset)
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

		if err := createSnapshot(dataset, initSnapshotName); err != nil {
			if !strings.Contains(err.Error(), "already exists") {
				return fmt.Errorf("create @%s snapshot for %q: %w", initSnapshotName, dataset, err)
			}
		}

		if err := rollbackToSnapshot(dataset, initSnapshotName); err != nil {
			return fmt.Errorf("rollback %q to @%s: %w", dataset, initSnapshotName, err)
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
