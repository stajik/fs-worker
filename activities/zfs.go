package activities

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

const (
	devicePollInterval = 200 * time.Millisecond
	deviceMaxWait      = 10 * time.Second
)

// ---------------------------------------------------------------------------
// Naming helpers
// ---------------------------------------------------------------------------

func datasetName(pool, id string) string {
	return pool + "/" + id
}

func datasetMountPoint(pool, id string) string {
	return "/mnt/" + pool + "/" + id
}

func zvolDevicePath(dataset string) string {
	return "/dev/zvol/" + dataset
}

func baseSnapshotFull(pool string) string {
	return pool + "/_base/vol@empty"
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

func validateID(id string) error {
	if id == "" {
		return fmt.Errorf("id must not be empty")
	}
	if strings.HasPrefix(id, "_") {
		return fmt.Errorf("id must not start with '_'")
	}
	if strings.ContainsAny(id, "/@") {
		return fmt.Errorf("id must not contain '/' or '@'")
	}
	for _, c := range id {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == ':') {
			return fmt.Errorf("id contains invalid character %q", c)
		}
	}
	return nil
}

func validateMode(mode BranchMode) error {
	switch mode {
	case BranchModeZvol, BranchModeZDS:
		return nil
	default:
		return fmt.Errorf("unsupported branch mode %q: must be %q or %q", mode, BranchModeZvol, BranchModeZDS)
	}
}

// ---------------------------------------------------------------------------
// ZFS CLI helpers
// ---------------------------------------------------------------------------

func runZFS(args ...string) (string, error) {
	out, err := exec.Command("zfs", args...).CombinedOutput()
	output := strings.TrimSpace(string(out))
	if err != nil {
		return "", fmt.Errorf("`zfs %s` failed: %s", strings.Join(args, " "), output)
	}
	return output, nil
}

func runSudoZFS(args ...string) (string, error) {
	cmdArgs := append([]string{"zfs"}, args...)
	out, err := exec.Command("sudo", cmdArgs...).CombinedOutput()
	output := strings.TrimSpace(string(out))
	if err != nil {
		return "", fmt.Errorf("`sudo zfs %s` failed: %s", strings.Join(args, " "), output)
	}
	return output, nil
}

func mountDataset(dataset string) error {
	_, err := runSudoZFS("mount", dataset)
	if err != nil {
		if strings.Contains(err.Error(), "already mounted") {
			return nil
		}
		return fmt.Errorf("mount dataset %q: %w", dataset, err)
	}
	return nil
}

func cloneSnapshot(snapshot, target string) error {
	_, err := runZFS("clone", "-o", "refreservation=none", snapshot, target)
	if err != nil {
		return fmt.Errorf("zfs clone %q -> %q: %w", snapshot, target, err)
	}
	return nil
}

func rollbackToSnapshot(dataset string, snap string) error {
	fullSnap := dataset + "@" + snap
	_, err := runZFS("rollback", "-r", fullSnap)
	if err != nil {
		return fmt.Errorf("zfs rollback %q: %w", snap, err)
	}
	return nil
}

func createSnapshot(dataset, snapName string) error {
	_, err := runZFS("snapshot", dataset+"@"+snapName)
	if err != nil {
		return fmt.Errorf("zfs snapshot %q: %w", dataset+"@"+snapName, err)
	}
	return nil
}

func createDataset(dataset string) error {
	_, err := runZFS("create", "-o", "canmount=noauto", dataset)
	if err != nil {
		return fmt.Errorf("zfs create %q: %w", dataset, err)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Device polling
// ---------------------------------------------------------------------------

func waitForDevice(ctx context.Context, path string) error {
	deadline := time.Now().Add(deviceMaxWait)
	for {
		if _, err := os.Stat(path); err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out after %s waiting for %q", deviceMaxWait, path)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(devicePollInterval):
		}
	}
}
