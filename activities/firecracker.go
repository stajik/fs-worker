package activities

import (
	"context"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"

	firecracker "github.com/firecracker-microvm/firecracker-go-sdk"
	"github.com/firecracker-microvm/firecracker-go-sdk/client/models"
)

const (
	// firecrackerBin is the path to the Firecracker binary.
	firecrackerBin = "/usr/local/bin/firecracker"

	// Default kernel image path (installed by vm-setup.sh).
	defaultKernelPath = "/opt/firecracker/vmlinux"

	// Default rootfs image paths (installed by vm-setup.sh).
	rootfsSquashfsPath = "/opt/firecracker/rootfs.squashfs"
	rootfsExt4Path     = "/opt/firecracker/rootfs.ext4"

	// Socket directory for Firecracker API sockets.
	socketDir = "/tmp/firecracker"

	// templateDir is the directory where template artifacts are stored.
	templateDir = "/opt/firecracker/templates"

	// vcpuCount is the number of vCPUs for each microVM.
	vcpuCount = 1

	// memSizeMiB is the memory allocated to each microVM in MiB.
	memSizeMiB = 256

	// dataImgName is the sparse file created inside a zds dataset mountpoint.
	dataImgName = "data.img"

	// baseDataImgPath is the pre-formatted ext4 image created by vm-setup.sh.
	// It is copied into each zds dataset mountpoint during InitBranch.
	baseDataImgPath = "/opt/firecracker/base-data.img"

	// cmdPlaceholderPath is a small empty file used as the "cmd" drive
	// placeholder during snapshot capture. On restore it is replaced with
	// a file containing the actual base64-encoded command.
	cmdPlaceholderPath = "/opt/firecracker/cmd-placeholder.img"
)

// templateDirFor returns the directory for a given template ID.
func templateDirFor(id string) string {
	return filepath.Join(templateDir, id)
}

// resolveDrivePath returns the block device or image path for the given branch.
func resolveDrivePath(pool, id string, mode BranchMode) (string, error) {
	switch mode {
	case BranchModeZvol:
		device := zvolDevicePath(datasetName(pool, id))
		if _, err := os.Stat(device); err != nil {
			return "", fmt.Errorf("zvol device %q not found: %w", device, err)
		}
		return device, nil

	case BranchModeZDS:
		mp := datasetMountPoint(pool, id)

		// The pre-formatted image is copied into the dataset during InitBranch.
		img := filepath.Join(mp, dataImgName)
		if _, err := os.Stat(img); err != nil {
			return "", fmt.Errorf("data image %q not found (was InitBranch called?): %w", img, err)
		}
		return img, nil

	default:
		return "", fmt.Errorf("unsupported mode %q", mode)
	}
}

// resolveTemplateArtifacts returns the paths to a template's snapshot, memory
// file, and squashfs rootfs. Returns an error if any artifact is missing.
func resolveTemplateArtifacts(templateID string) (snapshotPath, memFilePath, squashfsPath string, err error) {
	tplDir := templateDirFor(templateID)
	snapshotPath = filepath.Join(tplDir, "vm_state")
	memFilePath = filepath.Join(tplDir, "vm_mem")
	squashfsPath = filepath.Join(tplDir, "rootfs.squashfs")

	for _, p := range []string{snapshotPath, memFilePath, squashfsPath} {
		if _, err := os.Stat(p); err != nil {
			return "", "", "", fmt.Errorf("template artifact %q not found: %w", p, err)
		}
	}
	return snapshotPath, memFilePath, squashfsPath, nil
}

// newSocketPath creates a unique API socket path for a Firecracker instance.
func newSocketPath(id string) (string, error) {
	if err := os.MkdirAll(socketDir, 0755); err != nil {
		return "", fmt.Errorf("create socket dir: %w", err)
	}
	return filepath.Join(socketDir, fmt.Sprintf("fc-%s.sock", id)), nil
}

// ensureCmdPlaceholder creates the small placeholder file used as the "cmd"
// drive during snapshot capture. It is a no-op if the file already exists.
func ensureCmdPlaceholder() error {
	if _, err := os.Stat(cmdPlaceholderPath); err == nil {
		return nil
	}
	return os.WriteFile(cmdPlaceholderPath, make([]byte, 512), 0644)
}

// writeCmdDriveFile creates a temporary file containing the base64-encoded
// command for use as the "cmd" drive on snapshot restore. The caller must
// remove the file when done.
func writeCmdDriveFile(cmd string) (string, error) {
	cmdB64 := base64.StdEncoding.EncodeToString([]byte(cmd))
	f, err := os.CreateTemp("", "fc-cmd-*")
	if err != nil {
		return "", fmt.Errorf("create cmd drive temp file: %w", err)
	}
	// Write the base64 command followed by a newline, then pad to 512 bytes
	// so the block device has a clean sector-aligned size.
	buf := make([]byte, 512)
	copy(buf, cmdB64+"\n")
	if _, err := f.Write(buf); err != nil {
		f.Close()
		os.Remove(f.Name())
		return "", fmt.Errorf("write cmd drive: %w", err)
	}
	f.Close()
	return f.Name(), nil
}

// ---------------------------------------------------------------------------
// Machine config builders
// ---------------------------------------------------------------------------

// buildTemplateMachineConfig builds a Firecracker config for template creation:
// writable ext4 rootfs copy, no data drive, fc_nodata=1 in boot args.
func buildTemplateMachineConfig(socketPath, rootfsCopyPath, cmd string) firecracker.Config {
	cmdB64 := base64.StdEncoding.EncodeToString([]byte(cmd))
	bootArgs := "console=ttyS0 reboot=k panic=1 pci=off quiet init=/_fc_init.sh fc_nodata=1 fc_cmd=" + cmdB64

	rootDriveID := "rootfs"
	isRootDevice := true
	readWrite := false // is_read_only = false

	return firecracker.Config{
		SocketPath:      socketPath,
		KernelImagePath: defaultKernelPath,
		KernelArgs:      bootArgs,
		MachineCfg: models.MachineConfiguration{
			VcpuCount:  firecracker.Int64(vcpuCount),
			MemSizeMib: firecracker.Int64(memSizeMiB),
			Smt:        firecracker.Bool(false),
		},
		Drives: []models.Drive{
			{
				DriveID:      &rootDriveID,
				PathOnHost:   &rootfsCopyPath,
				IsRootDevice: &isRootDevice,
				IsReadOnly:   &readWrite,
			},
		},
	}
}

// buildExecConfig builds a Firecracker config for executing a command:
// read-only squashfs rootfs (from a template) + writable data drive, with the
// command passed via boot args. This is a cold boot — no snapshot restore.
func buildExecConfig(socketPath, squashfsPath, dataDrivePath, cmd string) firecracker.Config {
	cmdB64 := base64.StdEncoding.EncodeToString([]byte(cmd))
	bootArgs := "console=ttyS0 reboot=k panic=1 pci=off quiet init=/_fc_init.sh fc_cmd=" + cmdB64

	rootDriveID := "rootfs"
	dataDriveID := "data"
	isRootDevice := true
	notRootDevice := false
	readOnly := true
	readWrite := false

	return firecracker.Config{
		SocketPath:      socketPath,
		KernelImagePath: defaultKernelPath,
		KernelArgs:      bootArgs,
		MachineCfg: models.MachineConfiguration{
			VcpuCount:  firecracker.Int64(vcpuCount),
			MemSizeMib: firecracker.Int64(memSizeMiB),
			Smt:        firecracker.Bool(false),
		},
		Drives: []models.Drive{
			{
				DriveID:      &rootDriveID,
				PathOnHost:   &squashfsPath,
				IsRootDevice: &isRootDevice,
				IsReadOnly:   &readOnly,
			},
			{
				DriveID:      &dataDriveID,
				PathOnHost:   &dataDrivePath,
				IsRootDevice: &notRootDevice,
				IsReadOnly:   &readWrite,
			},
		},
	}
}

// buildSnapshotCaptureConfig builds a Firecracker config for snapshot capture:
// read-only squashfs rootfs + a data drive placeholder + a cmd drive placeholder.
// The VM boots, prints ===FC_READY===, and blocks reading the cmd drive.
// The data and cmd drives use placeholders so the drive layout matches
// what buildSnapshotRestoreConfig provides on restore.
func buildSnapshotCaptureConfig(socketPath, squashfsPath string) firecracker.Config {
	bootArgs := "console=ttyS0 reboot=k panic=1 pci=off quiet init=/_fc_init.sh fc_nodata=1"

	rootDriveID := "rootfs"
	dataDriveID := "data"
	cmdDriveID := "cmd"
	isRootDevice := true
	notRootDevice := false
	readOnly := true
	readWrite := false
	dummyDataPath := baseDataImgPath
	dummyCmdPath := cmdPlaceholderPath

	return firecracker.Config{
		SocketPath:      socketPath,
		KernelImagePath: defaultKernelPath,
		KernelArgs:      bootArgs,
		MachineCfg: models.MachineConfiguration{
			VcpuCount:  firecracker.Int64(vcpuCount),
			MemSizeMib: firecracker.Int64(memSizeMiB),
			Smt:        firecracker.Bool(false),
		},
		Drives: []models.Drive{
			{
				DriveID:      &rootDriveID,
				PathOnHost:   &squashfsPath,
				IsRootDevice: &isRootDevice,
				IsReadOnly:   &readOnly,
			},
			{
				DriveID:      &dataDriveID,
				PathOnHost:   &dummyDataPath,
				IsRootDevice: &notRootDevice,
				IsReadOnly:   &readWrite,
			},
			{
				DriveID:      &cmdDriveID,
				PathOnHost:   &dummyCmdPath,
				IsRootDevice: &notRootDevice,
				IsReadOnly:   &readOnly,
			},
		},
	}
}

// buildSnapshotRestoreConfig builds a Firecracker config that restores a VM
// from a previously captured snapshot. The squashfs rootfs, data drive, and
// cmd drive must be provided so Firecracker can re-attach the backing files.
// The cmd drive contains the base64-encoded command that the init script reads
// from /dev/vdc on resume.
func buildSnapshotRestoreConfig(socketPath, squashfsPath, dataDrivePath, cmdDrivePath, snapshotPath, memFilePath string) firecracker.Config {
	rootDriveID := "rootfs"
	dataDriveID := "data"
	cmdDriveID := "cmd"
	isRootDevice := true
	notRootDevice := false
	readOnly := true
	readWrite := false

	return firecracker.Config{
		SocketPath:      socketPath,
		KernelImagePath: defaultKernelPath,
		MachineCfg: models.MachineConfiguration{
			VcpuCount:  firecracker.Int64(vcpuCount),
			MemSizeMib: firecracker.Int64(memSizeMiB),
			Smt:        firecracker.Bool(false),
		},
		Drives: []models.Drive{
			{
				DriveID:      &rootDriveID,
				PathOnHost:   &squashfsPath,
				IsRootDevice: &isRootDevice,
				IsReadOnly:   &readOnly,
			},
			{
				DriveID:      &dataDriveID,
				PathOnHost:   &dataDrivePath,
				IsRootDevice: &notRootDevice,
				IsReadOnly:   &readWrite,
			},
			{
				DriveID:      &cmdDriveID,
				PathOnHost:   &cmdDrivePath,
				IsRootDevice: &notRootDevice,
				IsReadOnly:   &readOnly,
			},
		},
		Snapshot: firecracker.SnapshotConfig{
			MemFilePath:  memFilePath,
			SnapshotPath: snapshotPath,
			ResumeVM:     true,
		},
	}
}

// ---------------------------------------------------------------------------
// markerWriter — an io.Writer that buffers all writes and closes a channel
// when a specific marker string appears in the stream.
// ---------------------------------------------------------------------------

type markerWriter struct {
	mu     sync.Mutex
	buf    strings.Builder
	marker string
	ready  chan struct{}
	closed bool
}

func newMarkerWriter(marker string) *markerWriter {
	return &markerWriter{
		marker: marker,
		ready:  make(chan struct{}),
	}
}

func (w *markerWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	n, err := w.buf.Write(p)
	if !w.closed && w.marker != "" && strings.Contains(w.buf.String(), w.marker) {
		close(w.ready)
		w.closed = true
	}
	return n, err
}

func (w *markerWriter) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.buf.String()
}

// Ready returns a channel that is closed when the marker is found.
func (w *markerWriter) Ready() <-chan struct{} {
	return w.ready
}

// ---------------------------------------------------------------------------
// vmInstance
// ---------------------------------------------------------------------------

// vmInstance holds a running Firecracker VM and its captured output buffers.
type vmInstance struct {
	machine    *firecracker.Machine
	stdoutBuf  *markerWriter
	stderrBuf  *markerWriter
	socketPath string
}

// startFirecracker creates and starts a Firecracker VM with the given config.
// The caller is responsible for calling Wait (or pausing/snapshotting) and
// cleaning up the socket path.
// If marker is non-empty, the stdout writer will signal via Ready() when the
// marker appears in the output stream.
func startFirecracker(ctx context.Context, id string, cfg firecracker.Config, marker string) (*vmInstance, error) {
	stdoutBuf := newMarkerWriter(marker)
	stderrBuf := newMarkerWriter("")

	builder := firecracker.VMCommandBuilder{}.
		WithBin(firecrackerBin).
		WithSocketPath(cfg.SocketPath).
		WithStdout(stdoutBuf).
		WithStderr(stderrBuf)

	machineOpts := []firecracker.Opt{
		firecracker.WithProcessRunner(builder.Build(ctx)),
	}

	// When a snapshot is configured, pass WithSnapshot so the SDK uses the
	// snapshot-load handler list instead of the normal boot flow.
	snap := cfg.Snapshot
	if snap.MemFilePath != "" && snap.SnapshotPath != "" {
		machineOpts = append(machineOpts,
			firecracker.WithSnapshot(snap.MemFilePath, snap.SnapshotPath, func(sc *firecracker.SnapshotConfig) {
				sc.ResumeVM = snap.ResumeVM
			}),
		)
	}

	m, err := firecracker.NewMachine(ctx, cfg, machineOpts...)
	if err != nil {
		return nil, fmt.Errorf("create machine: %w", err)
	}

	if err := m.Start(ctx); err != nil {
		return nil, fmt.Errorf("start machine: %w", err)
	}

	return &vmInstance{
		machine:    m,
		stdoutBuf:  stdoutBuf,
		stderrBuf:  stderrBuf,
		socketPath: cfg.SocketPath,
	}, nil
}

// output returns the parsed stdout, stderr, and exit code from the VM serial
// console output.
func (v *vmInstance) output() (stdout, stderr string, exitCode int) {
	return parseVMOutput(v.stdoutBuf.String())
}

// rawOutput returns the raw captured stdout and stderr strings.
func (v *vmInstance) rawOutput() (string, string) {
	return v.stdoutBuf.String(), v.stderrBuf.String()
}

// ---------------------------------------------------------------------------
// runFromTemplate cold-boots a VM from a template's squashfs rootfs with the
// command in kernel boot args. This avoids Firecracker snapshot restore, which
// has reliability issues with serial console output and in-flight process
// state. Cold boot from squashfs is ~125ms and fully reliable.
// ---------------------------------------------------------------------------

func runFromTemplate(ctx context.Context, id, templateID, dataDrivePath, cmd string) (stdout, stderr string, exitCode int, rawStdout, rawStderr string, err error) {
	_, _, squashfsPath, err := resolveTemplateArtifacts(templateID)
	if err != nil {
		return "", "", -1, "", "", fmt.Errorf("resolve template %q: %w", templateID, err)
	}

	socketPath, err := newSocketPath(id)
	if err != nil {
		return "", "", -1, "", "", err
	}
	defer os.Remove(socketPath)

	cfg := buildExecConfig(socketPath, squashfsPath, dataDrivePath, cmd)

	vm, err := startFirecracker(ctx, id, cfg, "")
	if err != nil {
		return "", "", -1, "", "", err
	}

	// Wait for the VM to execute and exit (reboot -f).
	if err := vm.machine.Wait(ctx); err != nil {
		rawStdout, rawStderr = vm.rawOutput()
		return "", "", -1, rawStdout, rawStderr, fmt.Errorf("wait machine: %w", err)
	}

	rawStdout, rawStderr = vm.rawOutput()
	stdout, stderr, exitCode = vm.output()
	return stdout, stderr, exitCode, rawStdout, rawStderr, nil
}

// ---------------------------------------------------------------------------
// runFromSnapshot restores a VM from a template snapshot and waits for it to
// exit. The command is delivered via a small block device (/dev/vdc). This is
// kept alongside runFromTemplate for benchmarking snapshot vs cold-boot latency.
// ---------------------------------------------------------------------------

func runFromSnapshot(ctx context.Context, id, templateID, dataDrivePath, cmd string) (stdout, stderr string, exitCode int, rawStdout, rawStderr string, err error) {
	snapshotPath, memFilePath, squashfsPath, err := resolveTemplateArtifacts(templateID)
	if err != nil {
		return "", "", -1, "", "", fmt.Errorf("resolve template %q: %w", templateID, err)
	}

	socketPath, err := newSocketPath(id)
	if err != nil {
		return "", "", -1, "", "", err
	}
	defer os.Remove(socketPath)

	cmdDrivePath, err := writeCmdDriveFile(cmd)
	if err != nil {
		return "", "", -1, "", "", err
	}
	defer os.Remove(cmdDrivePath)

	cfg := buildSnapshotRestoreConfig(socketPath, squashfsPath, dataDrivePath, cmdDrivePath, snapshotPath, memFilePath)

	vm, err := startFirecracker(ctx, id, cfg, "")
	if err != nil {
		return "", "", -1, "", "", err
	}

	if err := vm.machine.Wait(ctx); err != nil {
		rawStdout, rawStderr = vm.rawOutput()
		return "", "", -1, rawStdout, rawStderr, fmt.Errorf("wait machine: %w", err)
	}

	rawStdout, rawStderr = vm.rawOutput()
	stdout, stderr, exitCode = vm.output()
	return stdout, stderr, exitCode, rawStdout, rawStderr, nil
}

// ---------------------------------------------------------------------------
// Output parsing
// ---------------------------------------------------------------------------

// parseVMOutput extracts structured stdout, stderr, and exit code from the
// VM serial console output delimited by ===FC_*=== markers.
func parseVMOutput(raw string) (stdout, stderr string, exitCode int) {
	raw = strings.ReplaceAll(raw, "\r", "")
	stdout = extractBetween(raw, "===FC_STDOUT_START===", "===FC_STDOUT_END===")
	stderr = extractBetween(raw, "===FC_STDERR_START===", "===FC_STDERR_END===")

	exitCode = -1
	re := regexp.MustCompile(`===FC_EXIT_CODE=(\d+)===`)
	if m := re.FindStringSubmatch(raw); len(m) == 2 {
		if v, err := strconv.Atoi(m[1]); err == nil {
			exitCode = v
		}
	}
	return
}

// extractBetween returns the content between two marker lines in s.
func extractBetween(s, startMarker, endMarker string) string {
	si := strings.Index(s, startMarker)
	if si < 0 {
		return ""
	}
	si += len(startMarker)
	// Skip the newline after the start marker.
	if si < len(s) && s[si] == '\n' {
		si++
	}
	ei := strings.Index(s[si:], endMarker)
	if ei < 0 {
		return strings.TrimRight(s[si:], "\n")
	}
	return strings.TrimRight(s[si:si+ei], "\n")
}
