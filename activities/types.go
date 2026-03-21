package activities

// BranchMode determines whether a branch is backed by a ZFS zvol (block
// device) or a ZFS dataset (filesystem).
type BranchMode string

const (
	// BranchModeZvol creates the branch as a ZFS zvol (block device at
	// /dev/zvol/<pool>/<id>), pre-formatted with ext4 by cloning the base
	// volume snapshot created during worker setup.
	BranchModeZvol BranchMode = "zvol"

	// BranchModeZDS creates the branch as a regular ZFS dataset (filesystem)
	// that can be mounted directly.
	BranchModeZDS BranchMode = "zds"
)

const (
	// initSnapshotName is the name of the initial snapshot created on every
	// new branch (e.g. <pool>/<id>@__init).
	initSnapshotName = "__init"
)

// InitBranchInput is the input payload for the InitBranch activity.
type InitBranchInput struct {
	// ID is the unique identifier for the branch. It becomes the dataset name
	// under the configured ZFS pool (e.g. testpool/<id>).
	ID string `json:"id"`

	// Mode selects the branch backing type: "zvol" (block device) or "zds"
	// (ZFS dataset / filesystem). Required.
	Mode BranchMode `json:"mode"`
}

// ExecInput is the input payload for the Exec activity.
type ExecInput struct {
	// ID is the branch identifier (matches the ZFS dataset name under the pool).
	ID string `json:"id"`

	// Mode is the branch backing type: "zvol" or "zds".
	Mode BranchMode `json:"mode"`

	// TemplateID is the template to boot from. The template must have been
	// created via CreateTemplate. The VM is restored from the template's
	// snapshot and the command is delivered via the serial console.
	TemplateID string `json:"template_id"`

	// Cmd is the command (shell script) to execute inside the Firecracker microVM.
	Cmd string `json:"cmd"`

	// TargetSnapshot is the snapshot to create after a successful execution.
	// On failure (non-zero exit code, timeout, or VM error) the branch is
	// rolled back to BaseSnapshot instead.
	TargetSnapshot string `json:"target_snapshot"`

	// BaseSnapshot is the snapshot the branch must be on before executing.
	// If the branch is on a newer snapshot, it will be rolled back. If the
	// snapshot doesn't exist or is not a valid rollback target, ZFS will error.
	// When set to "__init", the branch is created first via InitBranch.
	BaseSnapshot string `json:"base_snapshot"`

	// UseSnapshot, if true, restores the VM from the template snapshot instead
	// of cold-booting. Useful for benchmarking snapshot vs cold-boot latency.
	// Defaults to false (cold boot).
	UseSnapshot bool `json:"use_snapshot,omitempty"`
}

// ExecOutput is the result returned by the Exec activity.
type ExecOutput struct {
	// ExitCode is the exit code of the command.
	ExitCode int `json:"exit_code"`

	// Stdout captured from the command.
	Stdout string `json:"stdout"`

	// Stderr captured from the command.
	Stderr string `json:"stderr"`

	// TimedOut is true when the VM was killed because it approached the
	// activity deadline. Stdout/Stderr contain partial output captured
	// before the timeout.
	TimedOut bool `json:"timed_out,omitempty"`
}

// CreateTemplateInput is the input payload for the CreateTemplate activity.
type CreateTemplateInput struct {
	// ID is the unique identifier for the template.
	ID string `json:"id"`

	// Cmd is the command (shell script) to execute inside the Firecracker
	// microVM. The command runs against a fresh copy of the base ext4 rootfs
	// with no data volume attached.
	Cmd string `json:"cmd"`
}

// CreateTemplateOutput is the result returned by the CreateTemplate activity.
type CreateTemplateOutput struct {
	// ExitCode is the exit code of the command that ran inside the VM.
	ExitCode int `json:"exit_code"`

	// Stdout captured from the command.
	Stdout string `json:"stdout"`

	// Stderr captured from the command.
	Stderr string `json:"stderr"`
}
