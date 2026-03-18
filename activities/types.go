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

// InitBranchInput is the input payload for the InitBranch activity.
type InitBranchInput struct {
	// ID is the unique identifier for the branch. It becomes the dataset name
	// under the configured ZFS pool (e.g. testpool/<id>).
	ID string `json:"id"`

	// Mode selects the branch backing type: "zvol" (block device) or "zds"
	// (ZFS dataset / filesystem). Required.
	Mode BranchMode `json:"mode"`
}
