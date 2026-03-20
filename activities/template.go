package activities

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"go.temporal.io/sdk/activity"
)

// CreateTemplate runs a command in a Firecracker microVM backed by a fresh
// copy of the base ext4 rootfs (no data volume). After the command completes
// successfully it:
//  1. Converts the modified ext4 rootfs into a squashfs image.
//  2. Boots a new VM from the squashfs, pauses it, and takes a snapshot.
//
// All artifacts are stored under /opt/firecracker/templates/<id>/.
func (a *FsWorkerActivities) CreateTemplate(ctx context.Context, input CreateTemplateInput) (CreateTemplateOutput, error) {
	logger := activity.GetLogger(ctx)

	if err := validateID(input.ID); err != nil {
		return CreateTemplateOutput{}, fmt.Errorf("invalid id: %w", err)
	}
	if input.Cmd == "" {
		return CreateTemplateOutput{}, fmt.Errorf("cmd must not be empty")
	}

	logger.Info("CreateTemplate: starting", "id", input.ID, "cmd", input.Cmd)

	// Create the template output directory.
	tplDir := templateDirFor(input.ID)
	if err := os.MkdirAll(tplDir, 0755); err != nil {
		return CreateTemplateOutput{}, fmt.Errorf("create template dir %q: %w", tplDir, err)
	}

	// Copy the base ext4 rootfs for this template run (writable).
	rootfsCopy := filepath.Join(tplDir, "rootfs.ext4")
	cpOut, err := exec.Command("cp", "--sparse=always", rootfsExt4Path, rootfsCopy).CombinedOutput()
	if err != nil {
		return CreateTemplateOutput{}, fmt.Errorf("copy rootfs: %s", strings.TrimSpace(string(cpOut)))
	}

	// -----------------------------------------------------------------
	// Phase 1: Run the user command in a VM with the writable ext4 rootfs.
	// -----------------------------------------------------------------

	socketPath, err := newSocketPath("tpl-" + input.ID)
	if err != nil {
		return CreateTemplateOutput{}, fmt.Errorf("create socket path: %w", err)
	}
	defer os.Remove(socketPath)

	cfg := buildTemplateMachineConfig(socketPath, rootfsCopy, input.Cmd)

	// Derive a VM context with grace period.
	vmCtx := ctx
	if deadline, ok := ctx.Deadline(); ok {
		remaining := time.Until(deadline)
		if remaining > vmGracePeriod {
			var cancel context.CancelFunc
			vmCtx, cancel = context.WithDeadline(ctx, deadline.Add(-vmGracePeriod))
			defer cancel()
		}
	}

	vm, err := startFirecracker(vmCtx, "tpl-"+input.ID, cfg, "")
	if err != nil {
		return CreateTemplateOutput{}, fmt.Errorf("start firecracker: %w", err)
	}

	waitErr := vm.machine.Wait(vmCtx)

	stdout, stderr, exitCode := vm.output()
	if exitCode == -1 {
		rawStdout, rawStderr := vm.rawOutput()
		logger.Warn("CreateTemplate: markers not found in VM output",
			"id", input.ID,
			"raw_stdout", rawStdout,
			"raw_stderr", rawStderr,
		)
	}

	if waitErr != nil {
		if vmCtx.Err() != nil && ctx.Err() == nil {
			logger.Warn("CreateTemplate: VM timed out, returning partial output", "id", input.ID)
			return CreateTemplateOutput{
				ExitCode: -1,
				Stdout:   stdout,
				Stderr:   stderr,
			}, nil
		}
		return CreateTemplateOutput{}, fmt.Errorf("wait machine: %w", waitErr)
	}

	if exitCode != 0 {
		return CreateTemplateOutput{
			ExitCode: exitCode,
			Stdout:   stdout,
			Stderr:   stderr,
		}, fmt.Errorf("command exited with code %d", exitCode)
	}

	logger.Info("CreateTemplate: command finished, converting rootfs to squashfs", "id", input.ID)

	// -----------------------------------------------------------------
	// Phase 2: Convert the modified ext4 rootfs to squashfs.
	// -----------------------------------------------------------------

	squashfsPath := filepath.Join(tplDir, "rootfs.squashfs")
	if err := ext4ToSquashfs(rootfsCopy, squashfsPath); err != nil {
		return CreateTemplateOutput{}, fmt.Errorf("convert to squashfs: %w", err)
	}

	logger.Info("CreateTemplate: squashfs ready, booting snapshot VM", "id", input.ID)

	// -----------------------------------------------------------------
	// Phase 3: Boot a VM from the squashfs and snapshot it.
	// -----------------------------------------------------------------

	snapshotPath := filepath.Join(tplDir, "vm_state")
	memFilePath := filepath.Join(tplDir, "vm_mem")

	snapSocketPath, err := newSocketPath("tpl-snap-" + input.ID)
	if err != nil {
		return CreateTemplateOutput{}, fmt.Errorf("create snapshot socket path: %w", err)
	}
	defer os.Remove(snapSocketPath)

	// Ensure the cmd drive placeholder exists for snapshot capture.
	if err := ensureCmdPlaceholder(); err != nil {
		return CreateTemplateOutput{}, fmt.Errorf("ensure cmd placeholder: %w", err)
	}

	snapCfg := buildSnapshotCaptureConfig(snapSocketPath, squashfsPath)
	snapVM, err := startFirecracker(ctx, "tpl-snap-"+input.ID, snapCfg, "===FC_READY===")
	if err != nil {
		return CreateTemplateOutput{}, fmt.Errorf("start snapshot VM: %w", err)
	}

	snapDone := make(chan error, 1)
	go func() { snapDone <- snapVM.machine.Wait(ctx) }()

	select {
	case <-snapDone:
		// VM exited before it became ready — skip snapshot.
		snapRawStdout, snapRawStderr := snapVM.rawOutput()
		logger.Warn("CreateTemplate: snapshot VM exited before ready, skipping VM snapshot",
			"id", input.ID,
			"raw_stdout", snapRawStdout,
			"raw_stderr", snapRawStderr,
		)
	case <-snapVM.stdoutBuf.Ready():
		snapRawStdout, snapRawStderr := snapVM.rawOutput()
		logger.Info("CreateTemplate: snapshot VM ready, raw output",
			"id", input.ID,
			"raw_stdout", snapRawStdout,
			"raw_stderr", snapRawStderr,
		)
		// VM printed ===FC_READY=== — pause and snapshot immediately.
		if err := snapVM.machine.PauseVM(ctx); err != nil {
			logger.Warn("CreateTemplate: failed to pause VM, skipping snapshot", "id", input.ID, "error", err)
		} else if err := snapVM.machine.CreateSnapshot(ctx, memFilePath, snapshotPath); err != nil {
			logger.Warn("CreateTemplate: failed to create snapshot", "id", input.ID, "error", err)
		} else {
			logger.Info("CreateTemplate: VM snapshot created", "id", input.ID)
		}
		_ = snapVM.machine.StopVMM()
	case <-ctx.Done():
		snapRawStdout, snapRawStderr := snapVM.rawOutput()
		logger.Warn("CreateTemplate: snapshot VM timed out",
			"id", input.ID,
			"raw_stdout", snapRawStdout,
			"raw_stderr", snapRawStderr,
		)
		_ = snapVM.machine.StopVMM()
		return CreateTemplateOutput{}, ctx.Err()
	}

	// Clean up the intermediate ext4 copy.
	os.Remove(rootfsCopy)

	logger.Info("CreateTemplate: done", "id", input.ID, "dir", tplDir)

	return CreateTemplateOutput{
		ExitCode: exitCode,
		Stdout:   stdout,
		Stderr:   stderr,
	}, nil
}

// ext4ToSquashfs mounts an ext4 image and converts its contents to squashfs.
func ext4ToSquashfs(ext4Path, squashfsPath string) error {
	mountDir, err := os.MkdirTemp("", "ext4-mount-*")
	if err != nil {
		return fmt.Errorf("create temp mount dir: %w", err)
	}
	defer os.RemoveAll(mountDir)

	// Replay the journal so the image can be mounted read-only.
	// e2fsck exits 1 when it fixes errors — that's expected after reboot -f.
	out, err := exec.Command("e2fsck", "-fy", ext4Path).CombinedOutput()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
			// Exit code 1 = filesystem was modified/fixed — that's fine.
		} else {
			return fmt.Errorf("e2fsck: %s", strings.TrimSpace(string(out)))
		}
	}

	// Mount the ext4 image (requires root via sudo).
	out, err = exec.Command("sudo", "mount", "-o", "loop,ro", ext4Path, mountDir).CombinedOutput()
	if err != nil {
		return fmt.Errorf("mount ext4: %s", strings.TrimSpace(string(out)))
	}
	defer func() {
		exec.Command("sudo", "umount", mountDir).Run()
	}()

	// Create squashfs from the mounted directory.
	os.Remove(squashfsPath) // mksquashfs won't overwrite
	out, err = exec.Command("mksquashfs", mountDir, squashfsPath, "-comp", "zstd", "-noappend").CombinedOutput()
	if err != nil {
		return fmt.Errorf("mksquashfs: %s", strings.TrimSpace(string(out)))
	}

	return nil
}
