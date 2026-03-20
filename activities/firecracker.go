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

// buildSnapshotCaptureConfig builds a Firecracker config for snapshot capture:
// read-only squashfs rootfs + a data drive placeholder, no fc_cmd (snapshot mode).
// The VM boots, prints ===FC_READY===, and blocks on serial read.
// The data drive uses baseDataImgPath as a dummy so the drive layout matches
// what buildSnapshotRestoreConfig provides on restore.
func buildSnapshotCaptureConfig(socketPath, squashfsPath string) firecracker.Config {
	bootArgs := "console=ttyS0 reboot=k panic=1 pci=off quiet init=/_fc_init.sh fc_nodata=1"

	rootDriveID := "rootfs"
	dataDriveID := "data"
	isRootDevice := true
	notRootDevice := false
	readOnly := true
	readWrite := false
	dummyDataPath := baseDataImgPath

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
		},
	}
}

// buildSnapshotRestoreConfig builds a Firecracker config that restores a VM
// from a previously captured snapshot. The squashfs rootfs and data drive must
// be provided so Firecracker can re-attach the backing files.
func buildSnapshotRestoreConfig(socketPath, squashfsPath, dataDrivePath, snapshotPath, memFilePath string) firecracker.Config {
	rootDriveID := "rootfs"
	dataDriveID := "data"
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
// If stdinPreload is non-empty, an OS pipe is created and the preload data is
// written into the kernel pipe buffer BEFORE the VM starts. This guarantees
// the data is available to the guest serial port immediately on resume —
// critical for snapshot restore where the guest is blocked on serial read.
func startFirecracker(ctx context.Context, id string, cfg firecracker.Config, marker string, stdinPreload string) (*vmInstance, error) {
	stdoutBuf := newMarkerWriter(marker)
	stderrBuf := newMarkerWriter("")

	builder := firecracker.VMCommandBuilder{}.
		WithBin(firecrackerBin).
		WithSocketPath(cfg.SocketPath).
		WithStdout(stdoutBuf).
		WithStderr(stderrBuf)

	if stdinPreload != "" {
		fmt.Println("preloaded command")
		// Use an OS pipe so writes are kernel-buffered (typically 64 KB on
		// Linux). Writing the command before Start() ensures data is already
		// in the pipe buffer when the VM resumes from a snapshot.
		pr, pw, err := os.Pipe()
		if err != nil {
			return nil, fmt.Errorf("create stdin pipe: %w", err)
		}
		if _, err := fmt.Fprint(pw, stdinPreload); err != nil {
			pw.Close()
			pr.Close()
			return nil, fmt.Errorf("preload stdin: %w", err)
		}
		builder = builder.WithStdin(pr)
	}

	machineOpts := []firecracker.Opt{
		firecracker.WithProcessRunner(builder.Build(ctx)),
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
// runFromSnapshot restores a VM from a template snapshot, sends the command
// via stdin, and waits for the VM to exit.
// ---------------------------------------------------------------------------

func runFromSnapshot(ctx context.Context, id, templateID, dataDrivePath, cmd string) (stdout, stderr string, exitCode int, err error) {
	snapshotPath, memFilePath, squashfsPath, err := resolveTemplateArtifacts(templateID)
	if err != nil {
		return "", "", -1, fmt.Errorf("resolve template %q: %w", templateID, err)
	}

	socketPath, err := newSocketPath(id)
	if err != nil {
		return "", "", -1, err
	}
	defer os.Remove(socketPath)

	cfg := buildSnapshotRestoreConfig(socketPath, squashfsPath, dataDrivePath, snapshotPath, memFilePath)

	// Pre-encode the command and write it into the stdin pipe buffer BEFORE
	// the VM starts. The guest is blocked on `read -r CMD_B64 < /dev/ttyS0`
	// and will consume this immediately on resume.
	cmdB64 := base64.StdEncoding.EncodeToString([]byte(cmd))
	vm, err := startFirecracker(ctx, id, cfg, "", cmdB64+"\n")
	if err != nil {
		return "", "", -1, err
	}

	// Wait for the VM to execute and exit (reboot -f).
	if err := vm.machine.Wait(ctx); err != nil {
		rawStdout, rawStderr := vm.rawOutput()
		return rawStdout, rawStderr, -1, fmt.Errorf("wait machine: %w", err)
	}

	stdout, stderr, exitCode = vm.output()
	return stdout, stderr, exitCode, nil
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
