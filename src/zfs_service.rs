use std::ffi::CString;
use std::time::Duration;

use tokio::sync::Mutex;
use tonic::{Request, Response, Status};

use crate::worker_proto::{
    CreateFileSystemRequest, CreateFileSystemResponse, DeleteFileSystemRequest,
    DeleteFileSystemResponse, worker_server::Worker,
};

use zfs_core::DataSetType;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Default zvol size: 1 GiB.
const DEFAULT_VOLSIZE: u64 = 1 * 1024 * 1024 * 1024;

/// volblocksize default is 8 KiB; volsize must be a multiple of it.
const BLOCK_SIZE: u64 = 8 * 1024;

/// Snapshot name appended to every cache zvol: `<cache_zvol>@formatted`.
const CACHE_SNAP_SUFFIX: &str = "formatted";

// ---------------------------------------------------------------------------
// Naming helpers
// ---------------------------------------------------------------------------

/// ZFS pool name — overridable via the `ZFS_POOL` environment variable.
fn pool() -> String {
    std::env::var("ZFS_POOL").unwrap_or_else(|_| "testpool".to_string())
}

/// Fully-qualified zvol dataset name for a caller-supplied id.
/// e.g. `testpool/<id>`
fn zvol_name(id: &str) -> String {
    format!("{}/{}", pool(), id)
}

/// Linux block device path for a zvol.
/// e.g. `/dev/zvol/testpool/<id>`
fn zvol_device_path(dataset: &str) -> String {
    format!("/dev/zvol/{}", dataset)
}

/// Parent dataset that holds all cache zvols.
/// e.g. `testpool/_cache`
fn cache_parent() -> String {
    format!("{}/_cache", pool())
}

/// Cache zvol dataset for a given (already-rounded) volsize.
/// e.g. `testpool/_cache/1073741824`
fn cache_zvol_name(volsize: u64) -> String {
    format!("{}/{}", cache_parent(), volsize)
}

/// Fully-qualified snapshot name for the pre-formatted cache zvol.
/// e.g. `testpool/_cache/1073741824@formatted`
fn cache_snap_name(volsize: u64) -> String {
    format!("{}@{}", cache_zvol_name(volsize), CACHE_SNAP_SUFFIX)
}

// ---------------------------------------------------------------------------
// ZFS helpers
// ---------------------------------------------------------------------------

/// Open a [`zfs_core::Zfs`] handle.
fn lzc() -> Result<zfs_core::Zfs, Status> {
    zfs_core::Zfs::new().map_err(|e| Status::internal(format!("libzfs_core init failed: {e}")))
}

/// Round `size_bytes` up to the nearest `BLOCK_SIZE` multiple.
fn round_volsize(size_bytes: u64) -> u64 {
    (size_bytes + BLOCK_SIZE - 1) / BLOCK_SIZE * BLOCK_SIZE
}

/// Create a thin zvol with the given dataset name and volsize.
///
/// `nvpair::NvList` is not `Send`, so this is a plain (non-async) function
/// that must be called before any `.await` point in the caller, or inside
/// a scoped block so the list is dropped before the first await.
fn create_thin_zvol(dataset: &str, volsize: u64) -> Result<(), Status> {
    let mut props = nvpair::NvList::new();

    let volsize_key = CString::new("volsize").unwrap();
    let refreservation_key = CString::new("refreservation").unwrap();

    let rc = unsafe {
        nvpair_sys::nvlist_add_uint64(props.as_mut_ptr(), volsize_key.as_ptr(), volsize)
    };
    if rc != 0 {
        return Err(Status::internal(format!(
            "nvlist_add_uint64(volsize) failed with code {rc}"
        )));
    }

    // refreservation=0 → thin provisioning (equivalent to `zfs create -s`).
    let rc = unsafe {
        nvpair_sys::nvlist_add_uint64(props.as_mut_ptr(), refreservation_key.as_ptr(), 0)
    };
    if rc != 0 {
        return Err(Status::internal(format!(
            "nvlist_add_uint64(refreservation) failed with code {rc}"
        )));
    }

    lzc()?
        .create(dataset, DataSetType::Zvol, &props)
        .map_err(|e| {
            if e.raw_os_error() == Some(libc::EEXIST) {
                Status::already_exists(format!("dataset '{dataset}' already exists"))
            } else {
                Status::internal(format!("lzc_create('{dataset}') failed: {e}"))
            }
        })
}

/// Clone a snapshot into a new dataset, inheriting the thin-provisioning
/// property so the clone does not suddenly become thick.
fn clone_snapshot(snapshot: &str, target: &str) -> Result<(), Status> {
    // props must be dropped before any await; caller is responsible for that.
    let mut props = nvpair::NvList::new();

    // Inherit refreservation=0 on the clone explicitly — clones inherit the
    // origin's value, but being explicit prevents surprises.
    let refreservation_key = CString::new("refreservation").unwrap();
    unsafe {
        nvpair_sys::nvlist_add_uint64(props.as_mut_ptr(), refreservation_key.as_ptr(), 0)
    };

    lzc()?
        .clone_dataset(target, snapshot, props.as_mut())
        .map_err(|e| {
            if e.raw_os_error() == Some(libc::EEXIST) {
                Status::already_exists(format!("dataset '{target}' already exists"))
            } else {
                Status::internal(format!(
                    "lzc_clone('{target}' from '{snapshot}') failed: {e}"
                ))
            }
        })
}

// ---------------------------------------------------------------------------
// Process helpers
// ---------------------------------------------------------------------------

/// Run an external command on a dedicated blocking thread.
///
/// Uses `spawn_blocking` so the synchronous `std::process::Command` does not
/// block the async executor. The future only resolves once the process exits.
async fn run_blocking(program: &'static str, args: Vec<String>) -> Result<String, Status> {
    tokio::task::spawn_blocking(move || {
        let output = std::process::Command::new(program)
            .args(&args)
            .output()
            .map_err(|e| Status::internal(format!("failed to spawn `{program}`: {e}")))?;

        if output.status.success() {
            Ok(String::from_utf8_lossy(&output.stdout).into_owned())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
            Err(Status::internal(format!(
                "`{program} {}` failed ({}): {}",
                args.join(" "),
                output.status,
                stderr.trim(),
            )))
        }
    })
    .await
    .map_err(|e| Status::internal(format!("spawn_blocking panicked: {e}")))?
}

/// Wait for the kernel to expose a zvol block device under `/dev/zvol/…`.
///
/// The ZFS kernel module creates the device node asynchronously after
/// `lzc_create` / `lzc_clone` returns, so a short polling loop is required.
async fn wait_for_device(device: &str, max_wait: Duration) -> Result<(), Status> {
    let interval = Duration::from_millis(200);
    let mut elapsed = Duration::ZERO;

    loop {
        if tokio::fs::metadata(device).await.is_ok() {
            return Ok(());
        }
        if elapsed >= max_wait {
            return Err(Status::internal(format!(
                "timed out waiting for block device '{device}' to appear after {max_wait:?}"
            )));
        }
        tokio::time::sleep(interval).await;
        elapsed += interval;
    }
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/// Reject ids that would produce an invalid ZFS dataset name component.
fn validate_id(id: &str) -> Result<(), Status> {
    if id.is_empty() {
        return Err(Status::invalid_argument("id must not be empty"));
    }
    // Guard against callers sneaking in a path separator or reserved prefix.
    if id.starts_with('_') || id.contains('/') || id.contains('@') {
        return Err(Status::invalid_argument(
            "id must not start with '_' or contain '/' or '@'",
        ));
    }
    if !id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | ':'))
    {
        return Err(Status::invalid_argument(
            "id may only contain alphanumerics, hyphens, underscores, periods, and colons",
        ));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Snapshot cache
// ---------------------------------------------------------------------------

/// Ensure the pre-formatted cache snapshot for `volsize` exists, creating it
/// on the first call and returning immediately on subsequent calls.
///
/// The per-size `Mutex` inside [`ZfsService`] serialises concurrent requests
/// for the same size so that `mkfs.ext4` runs exactly once per size even
/// under concurrent load.
///
/// # Layout produced
/// ```text
/// testpool/_cache/          ← created once (ZFS_TYPE_FILESYSTEM)
/// testpool/_cache/<volsize> ← thin zvol, one per distinct size
/// testpool/_cache/<volsize>@formatted  ← the cached snapshot
/// ```
async fn ensure_cache(volsize: u64) -> Result<String, Status> {
    let snap = cache_snap_name(volsize);
    let zfs = lzc()?;

    // Fast path: snapshot already exists — no lock needed for a read check.
    if zfs.exists(snap.as_str()) {
        return Ok(snap);
    }

    // Slow path: build the cache entry.
    //
    // Create the _cache parent filesystem if it doesn't exist yet.
    // lzc_create with ZFS_TYPE_FILESYSTEM is idempotent when EEXIST is ignored.
    {
        let props = nvpair::NvList::new();
        let parent = cache_parent();
        let _ = lzc()?.create(parent.as_str(), DataSetType::Zfs, &props);
        // Ignore errors: if it already exists that's fine; any other error
        // will surface when we try to create the child zvol below.
    }

    // Create the cache zvol (thin).
    let cache_zvol = cache_zvol_name(volsize);
    let cache_device = zvol_device_path(&cache_zvol);

    // create_thin_zvol is sync and drops NvList before we hit any await.
    match create_thin_zvol(&cache_zvol, volsize) {
        Ok(()) => {}
        Err(e) if e.code() == tonic::Code::AlreadyExists => {
            // Another concurrent request won the race to create the zvol.
            // Fall through — the snapshot may or may not exist yet; we'll
            // check again after waiting for the device.
        }
        Err(e) => return Err(e),
    }

    // Wait for the kernel to expose the block device.
    wait_for_device(&cache_device, Duration::from_secs(10)).await?;

    // Re-check: the other racer may have already snapshotted by now.
    let zfs = lzc()?;
    if zfs.exists(snap.as_str()) {
        return Ok(snap);
    }

    // Format the cache zvol with ext4.
    //
    // -F                        : non-interactive
    // -L _cache/<volsize>       : label for identification
    // -E lazy_itable_init=0,
    //    lazy_journal_init=0    : eagerly zero inode tables and journal so
    //                             actual disk usage is fully settled here;
    //                             total bytes written is identical to the
    //                             lazy path — only the timing differs.
    let label = format!("_cache/{volsize}");
    let mkfs_args = vec![
        "-F".to_string(),
        "-L".to_string(),
        label,
        "-E".to_string(),
        "lazy_itable_init=0,lazy_journal_init=0".to_string(),
        cache_device.clone(),
    ];

    run_blocking("mkfs.ext4", mkfs_args)
        .await
        .map_err(|e| {
            // Best-effort cleanup so the next caller can retry from scratch.
            let zvol = cache_zvol.clone();
            tokio::spawn(async move {
                if let Ok(z) = zfs_core::Zfs::new() {
                    let _ = z.destroy(zvol.as_str());
                }
            });
            e
        })?;

    // Take the snapshot that will serve as the cache source.
    lzc()?
        .snapshot(std::iter::once(snap.as_str()))
        .map_err(|e| Status::internal(format!("lzc_snapshot('{snap}') failed: {e}")))?;

    Ok(snap)
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

/// gRPC service implementation.
///
/// `format_locks` serialises concurrent `CreateFileSystem` calls that share
/// the same rounded volsize so that the cache zvol + snapshot is built at
/// most once per size, even under concurrent load.
pub struct ZfsService {
    /// One mutex per distinct volsize currently being initialised.
    /// The outer `Mutex` guards the map itself; inner `Arc<Mutex<()>>`s
    /// serialise per-size work.
    format_locks: Mutex<std::collections::HashMap<u64, std::sync::Arc<tokio::sync::Mutex<()>>>>,
}

impl std::fmt::Debug for ZfsService {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ZfsService").finish()
    }
}

impl Default for ZfsService {
    fn default() -> Self {
        Self {
            format_locks: Mutex::new(std::collections::HashMap::new()),
        }
    }
}

#[tonic::async_trait]
impl Worker for ZfsService {
    /// Create a ZFS zvol named `<pool>/<id>` pre-formatted with ext4.
    ///
    /// # Fast path (cache hit)
    /// If a pre-formatted snapshot already exists for this volsize, the zvol
    /// is created by cloning that snapshot — no `mkfs.ext4` is run.
    ///
    /// # Slow path (cache miss)
    /// On the first call for a given volsize:
    ///   1. Create `<pool>/_cache/<volsize>` (thin zvol).
    ///   2. Format it with `mkfs.ext4` (blocking, on a dedicated thread).
    ///   3. Snapshot it as `<pool>/_cache/<volsize>@formatted`.
    ///   4. Clone the snapshot to `<pool>/<id>`.
    ///
    /// Subsequent calls for the same size skip straight to step 4.
    async fn create_file_system(
        &self,
        request: Request<CreateFileSystemRequest>,
    ) -> Result<Response<CreateFileSystemResponse>, Status> {
        let req = request.into_inner();
        validate_id(&req.id)?;

        let size_bytes = if req.size_bytes == 0 {
            DEFAULT_VOLSIZE
        } else {
            req.size_bytes
        };
        let volsize = round_volsize(size_bytes);

        let target_dataset = zvol_name(&req.id);
        let target_device = zvol_device_path(&target_dataset);

        // Acquire (or create) the per-size lock so that concurrent requests
        // for the same size serialise through ensure_cache only once.
        let size_lock = {
            let mut map = self.format_locks.lock().await;
            map.entry(volsize)
                .or_insert_with(|| std::sync::Arc::new(tokio::sync::Mutex::new(())))
                .clone()
        };
        let _guard = size_lock.lock().await;

        // ── Ensure the pre-formatted cache snapshot exists ────────────────
        let cache_snap = ensure_cache(volsize).await?;

        // ── Clone the snapshot to produce the caller's zvol ───────────────
        // clone_snapshot is sync and drops NvList before the next await.
        clone_snapshot(&cache_snap, &target_dataset)?;

        // ── Wait for the cloned device node to appear ─────────────────────
        wait_for_device(&target_device, Duration::from_secs(10)).await?;

        Ok(Response::new(CreateFileSystemResponse {
            zvol: target_dataset,
            device: target_device,
            fs_type: "ext4".to_string(),
            size_bytes: volsize,
        }))
    }

    /// Destroy the zvol identified by `id`.
    ///
    /// Uses `lzc_destroy`. Returns `NOT_FOUND` if the zvol does not exist.
    /// The cache zvols under `_cache/` are never touched by this call.
    async fn delete_file_system(
        &self,
        request: Request<DeleteFileSystemRequest>,
    ) -> Result<Response<DeleteFileSystemResponse>, Status> {
        let req = request.into_inner();
        validate_id(&req.id)?;

        let name = zvol_name(&req.id);

        lzc()?.destroy(name.as_str()).map_err(|e| {
            if e.raw_os_error() == Some(libc::ENOENT) {
                Status::not_found(format!("filesystem '{}' not found", req.id))
            } else {
                Status::internal(format!("lzc_destroy('{}') failed: {e}", req.id))
            }
        })?;

        Ok(Response::new(DeleteFileSystemResponse {}))
    }
}
