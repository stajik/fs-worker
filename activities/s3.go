package activities

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/s3/manager"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

const (
	// maxPrefetchConcurrency is the maximum number of S3 downloads that
	// can run in parallel during branch reconstruction.
	maxPrefetchConcurrency = 4
)

// countingReader wraps an io.Reader and counts the total bytes read through
// it. The count is updated atomically so it is safe to read after the
// upload completes.
//
// Crucially, countingReader does NOT implement io.WriterTo. This prevents
// io.Copy (used internally by the upload manager's buffer pool) from
// short-circuiting our Read method via a WriterTo fast-path on the
// underlying reader (e.g. *os.File from StdoutPipe).
type countingReader struct {
	r io.Reader
	n atomic.Int64
}

func newCountingReader(r io.Reader) *countingReader {
	return &countingReader{r: r}
}

func (cr *countingReader) Read(p []byte) (int, error) {
	n, err := cr.r.Read(p)
	cr.n.Add(int64(n))
	return n, err
}

// BytesRead returns the total number of bytes read so far.
func (cr *countingReader) BytesRead() int64 {
	return cr.n.Load()
}

// Verify at compile time that countingReader implements ONLY io.Reader and
// not io.WriterTo (which would let io.Copy bypass our Read).
var _ io.Reader = (*countingReader)(nil)

// newS3Client creates an S3 client configured for the given region.
// It uses the default credential chain (instance profile, env vars, etc.).
func newS3Client(ctx context.Context, region string) (*s3.Client, error) {
	cfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(region))
	if err != nil {
		return nil, fmt.Errorf("load AWS config: %w", err)
	}
	return s3.NewFromConfig(cfg), nil
}

// uploadSnapshotDiff streams a ZFS diff to S3. The object key is
// "<branchID>/<targetSnapName>".
//
// When baseSnap is __init, it sends a full stream so that reconstruction
// can apply it over a freshly initialised branch (whose __init won't match
// the original):
//
//	zfs send <dataset>@<targetSnap>
//
// Otherwise it sends an incremental stream:
//
//	zfs send -i <dataset>@<baseSnap> <dataset>@<targetSnap>
//
// Stdout is piped directly into an S3 multipart upload so the diff never
// needs to be materialized on disk. The manager.Uploader handles chunking
// the stream automatically, which avoids the Content-Length requirement
// that a plain PutObject imposes on unseekable readers.
//
// A countingReader sits between zfs-send's stdout pipe and the upload
// manager to track the total bytes streamed. The countingReader intentionally
// does not implement io.WriterTo so that io.Copy (used inside the manager)
// cannot bypass Read() via the underlying *os.File's WriteTo/sendfile path.
//
// Returns the number of bytes uploaded, or 0 if S3 is not configured.
func (a *FsWorkerActivities) uploadSnapshotDiff(ctx context.Context, dataset, branchID, baseSnap, targetSnap string) (int64, error) {
	if a.s3Bucket == "" {
		return 0, nil // S3 not configured — skip upload
	}

	client, err := a.getS3Client(ctx)
	if err != nil {
		return 0, err
	}

	targetRef := dataset + "@" + targetSnap

	// When the base is __init, send a full stream that includes __init and
	// the target snapshot. Otherwise send an incremental stream.
	var cmd *exec.Cmd
	if baseSnap == initSnapshotName {
		cmd = exec.CommandContext(ctx, "zfs", "send", "-w", targetRef)
	} else {
		baseRef := dataset + "@" + baseSnap
		cmd = exec.CommandContext(ctx, "zfs", "send", "-w", "-i", baseRef, targetRef)
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return 0, fmt.Errorf("zfs send stdout pipe: %w", err)
	}

	var stderrBuf strings.Builder
	cmd.Stderr = &stderrBuf

	if err := cmd.Start(); err != nil {
		return 0, fmt.Errorf("zfs send start: %w", err)
	}

	key := branchID + "/" + targetSnap

	// Wrap stdout in a countingReader. The wrapper only exposes io.Reader,
	// hiding the *os.File's io.WriterTo so every byte flows through Read().
	cr := newCountingReader(stdout)

	uploader := manager.NewUploader(client)
	_, uploadErr := uploader.Upload(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(a.s3Bucket),
		Key:         aws.String(key),
		Body:        cr,
		ContentType: aws.String("application/octet-stream"),
	})

	// Always wait for zfs send to finish regardless of upload result.
	cmdErr := cmd.Wait()

	if uploadErr != nil {
		return cr.BytesRead(), fmt.Errorf("s3 upload %q: %w", key, uploadErr)
	}
	if cmdErr != nil {
		return cr.BytesRead(), fmt.Errorf("zfs send %s: %s: %w", targetRef, stderrBuf.String(), cmdErr)
	}

	return cr.BytesRead(), nil
}

// ---------------------------------------------------------------------------
// Download / Reconstruction
// ---------------------------------------------------------------------------

// downloadSnapshotDiff downloads an incremental ZFS diff from S3 and applies
// it to the dataset via `zfs receive -F`. The object key is
// "<branchID>/<snapName>".
//
// The -F flag forces a rollback of the dataset to the most recent snapshot
// before applying the incremental stream, which is required for `zfs receive`
// to accept it.
//
// Returns the number of bytes downloaded.
func (a *FsWorkerActivities) downloadSnapshotDiff(ctx context.Context, dataset, branchID, snapName string) (int64, error) {
	if a.s3Bucket == "" {
		return 0, fmt.Errorf("s3 bucket not configured — cannot download snapshot diff")
	}

	client, err := a.getS3Client(ctx)
	if err != nil {
		return 0, err
	}

	key := branchID + "/" + snapName

	getOut, err := client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(a.s3Bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		return 0, fmt.Errorf("s3 get %q: %w", key, err)
	}
	defer getOut.Body.Close()

	cr := newCountingReader(getOut.Body)

	// zfs receive <dataset> applies the stream.
	cmd := exec.CommandContext(ctx, "zfs", "receive", dataset)
	cmd.Stdin = cr

	var stderrBuf strings.Builder
	cmd.Stderr = &stderrBuf

	if err := cmd.Run(); err != nil {
		return cr.BytesRead(), fmt.Errorf("zfs receive -F %s (from s3://%s/%s): %s: %w",
			dataset, a.s3Bucket, key, stderrBuf.String(), err)
	}

	return cr.BytesRead(), nil
}

// prefetchedDiff holds a snapshot diff that was downloaded from S3 to a local
// temporary file. The file is ready to be piped into `zfs receive`.
type prefetchedDiff struct {
	SnapName string        // snapshot name
	Path     string        // path to the temp file
	Size     int64         // bytes downloaded
	Duration time.Duration // wall-clock time for this download
	Err      error         // non-nil if the download failed
	ready    chan struct{} // closed when this slot's download is done
}

// downloadToFile downloads a single snapshot diff from S3 into a temporary
// file on disk. Returns the temp file path and the number of bytes written.
func (a *FsWorkerActivities) downloadToFile(ctx context.Context, branchID, snapName string) (path string, size int64, err error) {
	client, err := a.getS3Client(ctx)
	if err != nil {
		return "", 0, err
	}

	key := branchID + "/" + snapName

	getOut, err := client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(a.s3Bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		return "", 0, fmt.Errorf("s3 get %q: %w", key, err)
	}
	defer getOut.Body.Close()

	f, err := os.CreateTemp("", "zfs-diff-*.stream")
	if err != nil {
		return "", 0, fmt.Errorf("create temp file: %w", err)
	}

	n, copyErr := io.Copy(f, getOut.Body)
	// Close the file regardless — we'll reopen it for zfs receive.
	closeErr := f.Close()

	if copyErr != nil {
		os.Remove(f.Name())
		return "", 0, fmt.Errorf("download s3://%s/%s: %w", a.s3Bucket, key, copyErr)
	}
	if closeErr != nil {
		os.Remove(f.Name())
		return "", 0, fmt.Errorf("close temp file: %w", closeErr)
	}

	return f.Name(), n, nil
}

// applyDiffFromFile pipes a local file into `zfs receive -F <dataset>`.
func applyDiffFromFile(ctx context.Context, dataset, filePath string) error {
	f, err := os.Open(filePath)
	if err != nil {
		return fmt.Errorf("open diff file %q: %w", filePath, err)
	}
	defer f.Close()

	cmd := exec.CommandContext(ctx, "zfs", "receive", dataset)
	cmd.Stdin = f

	var stderrBuf strings.Builder
	cmd.Stderr = &stderrBuf

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("zfs receive -F %s (from %s): %s: %w",
			dataset, filePath, stderrBuf.String(), err)
	}

	return nil
}

// prefetchSnapshotDiffs downloads snapshot diffs from S3 concurrently (up to
// maxPrefetchConcurrency) while applying them sequentially as soon as each
// blob becomes available. This pipelines network I/O (S3 → temp file) with
// disk I/O (temp file → zfs receive) so the applier never waits for blobs
// that aren't needed yet.
//
// Each slot has a `ready` channel that is closed when the download finishes.
// The applier iterates in order, blocking on each slot's channel, so diffs
// are always applied in the correct chronological sequence regardless of
// which downloads finish first.
//
// Per-blob fs_s3_download_duration and fs_s3_download_bytes metrics are
// recorded for each successfully downloaded diff via the provided callbacks.
//
// Returns the total bytes downloaded across all diffs.
//
// Temporary files are cleaned up after each successful apply, or all at once
// if an error occurs.
func (a *FsWorkerActivities) prefetchSnapshotDiffs(ctx context.Context, dataset, branchID string, snapshots []string, downloadDurationRecorder func(time.Duration), downloadBytesRecorder func(float64)) (int64, error) {
	if len(snapshots) == 0 {
		return 0, nil
	}

	// Initialise per-slot results with a ready channel each.
	slots := make([]prefetchedDiff, len(snapshots))
	for i, snap := range snapshots {
		slots[i] = prefetchedDiff{
			SnapName: snap,
			ready:    make(chan struct{}),
		}
	}

	// Launch downloaders — up to maxPrefetchConcurrency at a time.
	sem := make(chan struct{}, maxPrefetchConcurrency)
	for i := range snapshots {
		go func(idx int) {
			defer close(slots[idx].ready)

			// Acquire semaphore slot.
			select {
			case sem <- struct{}{}:
			case <-ctx.Done():
				slots[idx].Err = ctx.Err()
				return
			}
			defer func() { <-sem }()

			dlStart := time.Now()
			path, size, err := a.downloadToFile(ctx, branchID, snapshots[idx])
			slots[idx].Path = path
			slots[idx].Size = size
			slots[idx].Duration = time.Since(dlStart)
			slots[idx].Err = err
		}(i)
	}

	// cleanupFrom removes temp files from index `from` onward, waiting for
	// each slot's download to finish first so we don't race on the Path field.
	cleanupFrom := func(from int) {
		for j := from; j < len(slots); j++ {
			<-slots[j].ready
			if slots[j].Path != "" {
				os.Remove(slots[j].Path)
				slots[j].Path = ""
			}
		}
	}

	// Apply diffs sequentially in order, blocking on each slot's ready
	// channel so we start applying as soon as the next blob is available.
	var totalBytes int64
	for i := range slots {
		// Wait for this slot's download to complete.
		select {
		case <-slots[i].ready:
		case <-ctx.Done():
			cleanupFrom(i)
			return totalBytes, ctx.Err()
		}

		if slots[i].Err != nil {
			cleanupFrom(i)
			return totalBytes, fmt.Errorf("download snapshot %q: %w", slots[i].SnapName, slots[i].Err)
		}

		// Record per-blob metrics now that the download succeeded.
		downloadDurationRecorder(slots[i].Duration)
		downloadBytesRecorder(float64(slots[i].Size))

		if err := applyDiffFromFile(ctx, dataset, slots[i].Path); err != nil {
			// Clean up this file and all remaining.
			os.Remove(slots[i].Path)
			slots[i].Path = ""
			cleanupFrom(i + 1)
			return totalBytes, fmt.Errorf("apply snapshot %q: %w", slots[i].SnapName, err)
		}

		totalBytes += slots[i].Size
		// Clean up the temp file immediately after successful apply.
		os.Remove(slots[i].Path)
		slots[i].Path = ""
	}

	return totalBytes, nil
}

// ---------------------------------------------------------------------------
// S3 client lifecycle
// ---------------------------------------------------------------------------

// getS3Client returns a cached S3 client, creating one on first use.
func (a *FsWorkerActivities) getS3Client(ctx context.Context) (*s3.Client, error) {
	if a.s3Client != nil {
		return a.s3Client, nil
	}

	client, err := newS3Client(ctx, a.s3Region)
	if err != nil {
		return nil, err
	}
	a.s3Client = client
	return client, nil
}
