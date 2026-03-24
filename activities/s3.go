package activities

import (
	"context"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"sync/atomic"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/s3/manager"
	"github.com/aws/aws-sdk-go-v2/service/s3"
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

// uploadSnapshotDiff streams an incremental ZFS diff between baseSnap and
// targetSnap to S3. The object key is "<branchID>/<targetSnapName>".
//
// It runs:
//
//	zfs send -i <dataset>@<baseSnap> <dataset>@<targetSnap>
//
// and pipes stdout directly into an S3 multipart upload so the diff never
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

	baseRef := dataset + "@" + baseSnap
	targetRef := dataset + "@" + targetSnap

	// zfs send -i <base> <target> produces an incremental stream.
	cmd := exec.CommandContext(ctx, "zfs", "send", "-i", baseRef, targetRef)

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
		return cr.BytesRead(), fmt.Errorf("zfs send -i %s %s: %s: %w", baseRef, targetRef, stderrBuf.String(), cmdErr)
	}

	return cr.BytesRead(), nil
}

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
