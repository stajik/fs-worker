use std::ffi::CString;
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use temporalio_macros::activities;
use temporalio_sdk::activities::{ActivityContext, ActivityError};
use tokio::sync::Mutex;
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
// Activity input / output types
// ---------------------------------------------------------------------------

/// Input for the `create_file_system` activity.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateFileSystemInput {
    /// Unique identifier for the filesystem. Used as the zvol name under the
    /// configured ZFS pool (e.g. `testpool/<id>`).
    pub id: String,

    /// Size of the zvol in bytes. Defaults to 1 GiB when `0` or absent.
    #[serde(default)]
    pub size_bytes: u64,
}

/// Output of the `create_file_system` activity.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateFileSystemOutput {
    /// Fully-qualified zvol dataset name, e.g. `testpool/my-fs`.
    pub zvol: String,

    /// Block device path, e.g. `/dev/zvol/testpool/my-fs`.
    pub device: String,

    /// Filesystem type formatted onto the device (always `"ext4"`).
    pub fs_type: String,

    /// Actual zvol size in bytes (rounded up to 8 KiB boundary).
    pub size_bytes: u64,
}

/// Input for the `delete_file_system` activity.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeleteFileSystemInput {
    /// Identifier of the filesystem to delete.
    pub id: String,
}

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

/// Linux block device path for a zvol dataset.
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
// Validation
// ---------------------------------------------------------------------------

/// Reject ids that would produce an invalid ZFS dataset name component.
fn validate_id(id: &str) -> Result<(), ActivityError> {
    if id.is_empty() {
        return Err(anyhow::anyhow!("id must not be empty").into());
    }
    // Guard against callers sneaking into the _cache namespace or forming an
    // invalid dataset path.
    if id.starts_with('_') || id.contains('/') || id.contains('@') {
        return Err(anyhow::anyhow!(
            "id must not start with '_' or contain '/' or '@'"
        )
        .into());
    }
    if !id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | ':'))
    {
        return Err(anyhow::anyhow!(
            "id may only contain alphanumerics, hyphens, underscores, periods, and colons"
        )
        .into());
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// ZFS helpers
// ---------------------------------------------------------------------------

/// Open a [`zfs_core::Zfs`] handle.
fn lzc() -> Result<zfs_core::Zfs, ActivityError> {
    zfs_core::Zfs::new()
        .map_err(|e| anyhow::anyhow!("libzfs_core init failed: {e}").into())
}

/// Round `size_bytes` up to the nearest `BLOCK_SIZE` multiple.
fn round_volsize(size_bytes: u64) -> u64 {
    (size_bytes + BLOCK_SIZE - 1) / BLOCK_SIZE * BLOCK_SIZE
}



/// Clone a snapshot into a new dataset with thin provisioning preserved.
///
/// `nvpair::NvList` is not `Send` — must be called and dropped before any
/// `.await` in the caller.
fn clone_snapshot(snapshot: &str, target: &str) -> Result<(), ActivityError> {
    let mut props = nvpair::NvList::new();

    // Explicitly set refreservation=0 on the clone so it stays thin.
    let refreservation_key = CString::new("refreservation").unwrap();
    unsafe {
        nvpair_sys::nvlist_add_uint64(props.as_mut_ptr(), refreservation_key.as_ptr(), 0)
    };

    lzc()?
        .clone_dataset(target, snapshot, props.as_mut())
        .map_err(|e| {
            if e.raw_os_error() == Some(libc::EEXIST) {
                anyhow::anyhow!("dataset '{target}' already exists").into()
            } else {
                anyhow::anyhow!("lzc_clone('{target}' from '{snapshot}') failed: {e}").into()
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
async fn run_blocking(program: &'static str, args: Vec<String>) -> Result<String, ActivityError> {
    // spawn_blocking returns JoinHandle<Result<String, anyhow::Error>>.
    // .await gives Result<Result<String, anyhow::Error>, JoinError>.
    // We flatten both error layers into ActivityError.
    let result: Result<String, anyhow::Error> = tokio::task::spawn_blocking(move || {
        let output = std::process::Command::new(program)
            .args(&args)
            .output()
            .map_err(|e| anyhow::anyhow!("failed to spawn `{program}`: {e}"))?;

        if output.status.success() {
            Ok(String::from_utf8_lossy(&output.stdout).into_owned())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
            Err(anyhow::anyhow!(
                "`{program} {}` failed ({}): {}",
                args.join(" "),
                output.status,
                stderr.trim(),
            ))
        }
    })
    .await
    .map_err(|e| anyhow::anyhow!("spawn_blocking panicked: {e}"))?;

    result.map_err(Into::into)
}

/// Wait for the kernel to expose a zvol block device under `/dev/zvol/…`.
///
/// The ZFS kernel module creates the device node asynchronously after
/// `lzc_create` / `lzc_clone` returns, so a short polling loop is required.
async fn wait_for_device(device: &str, max_wait: Duration) -> Result<(), ActivityError> {
    let interval = Duration::from_millis(200);
    let mut elapsed = Duration::ZERO;

    loop {
        if tokio::fs::metadata(device).await.is_ok() {
            return Ok(());
        }
        if elapsed >= max_wait {
            return Err(anyhow::anyhow!(
                "timed out waiting for block device '{device}' to appear after {max_wait:?}"
            )
            .into());
        }
        tokio::time::sleep(interval).await;
        elapsed += interval;
    }
}

// ---------------------------------------------------------------------------
// Snapshot cache
// ---------------------------------------------------------------------------

/// Ensure the pre-formatted cache snapshot for `volsize` exists.
///
/// On the first call for a given size this creates the cache zvol, runs
/// `mkfs.ext4` on it, and snapshots the result. Subsequent calls return
/// immediately once the snapshot is confirmed to exist.
///
/// # Pool layout produced
/// ```text
/// testpool/_cache/                    ← ZFS filesystem (parent)
/// testpool/_cache/<volsize>           ← thin zvol
/// testpool/_cache/<volsize>@formatted ← pre-formatted snapshot (cache key)
/// ```
async fn ensure_cache(volsize: u64) -> Result<String, ActivityError> {
    let snap = cache_snap_name(volsize);

    // Fast path — snapshot already exists.
    if lzc()?.exists(snap.as_str()) {
        return Ok(snap);
    }

    // Ensure the _cache parent filesystem exists (idempotent).
    {
        let props = nvpair::NvList::new();
        let parent = cache_parent();
        let _ = lzc()?.create(parent.as_str(), DataSetType::Zfs, &props);
    }

    // Create the cache zvol (thin).  Ignore EEXIST — a concurrent caller may
    // have beaten us to it.
    let cache_zvol = cache_zvol_name(volsize);
    let cache_device = zvol_device_path(&cache_zvol);

    if let Err(e) = lzc()?.create(cache_zvol.as_str(), DataSetType::Zvol, &{
        // Build props in a scoped block so NvList is dropped before any await.
        let volsize_key = CString::new("volsize").unwrap();
        let refreservation_key = CString::new("refreservation").unwrap();
        let mut props = nvpair::NvList::new();
        unsafe {
            nvpair_sys::nvlist_add_uint64(props.as_mut_ptr(), volsize_key.as_ptr(), volsize);
            nvpair_sys::nvlist_add_uint64(props.as_mut_ptr(), refreservation_key.as_ptr(), 0);
        }
        props
    }) {
        // EEXIST is fine — a concurrent caller already created the zvol.
        if e.raw_os_error() != Some(libc::EEXIST) {
            return Err(anyhow::anyhow!("lzc_create cache zvol failed: {e}").into());
        }
    }

    // Wait for the kernel to expose the block device.
    wait_for_device(&cache_device, Duration::from_secs(10)).await?;

    // Re-check: a concurrent caller may have snapshotted between our first
    // check and now.
    if lzc()?.exists(snap.as_str()) {
        return Ok(snap);
    }

    // Format the cache zvol with ext4.
    //
    // -F                        : non-interactive
    // -L _cache/<volsize>       : label for easy identification
    // -E lazy_itable_init=0,
    //    lazy_journal_init=0    : eagerly zero inode tables and journal —
    //                             same total bytes as lazy init, but all
    //                             writes happen now so disk usage is fully
    //                             settled when this function returns.
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

    // Snapshot the formatted zvol — this is the cache entry.
    lzc()?
        .snapshot(std::iter::once(snap.as_str()))
        .map_err(|e| -> ActivityError {
            anyhow::anyhow!("lzc_snapshot('{snap}') failed: {e}").into()
        })?;

    Ok(snap)
}

// ---------------------------------------------------------------------------
// Activity implementation
// ---------------------------------------------------------------------------

/// Temporal activity worker for ZFS filesystem management.
///
/// `format_locks` serialises concurrent `create_file_system` calls that share
/// the same rounded volsize so that the cache zvol + snapshot is built at most
/// once per size, even under concurrent load.
pub struct FsWorkerActivities {
    /// One mutex per distinct volsize currently being initialised.
    /// The outer `Mutex` guards the map; inner `Arc<Mutex<()>>` serialises
    /// per-size work.
    format_locks: Mutex<std::collections::HashMap<u64, Arc<tokio::sync::Mutex<()>>>>,
}

impl FsWorkerActivities {
    pub fn new() -> Self {
        Self {
            format_locks: Mutex::new(std::collections::HashMap::new()),
        }
    }
}

impl Default for FsWorkerActivities {
    fn default() -> Self {
        Self::new()
    }
}

#[activities]
impl FsWorkerActivities {
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
    #[activity]
    pub async fn create_file_system(
        self: Arc<Self>,
        _ctx: ActivityContext,
        input: CreateFileSystemInput,
    ) -> Result<CreateFileSystemOutput, ActivityError> {
        validate_id(&input.id)?;

        let size_bytes = if input.size_bytes == 0 {
            DEFAULT_VOLSIZE
        } else {
            input.size_bytes
        };
        let volsize = round_volsize(size_bytes);

        let target_dataset = zvol_name(&input.id);
        let target_device = zvol_device_path(&target_dataset);

        // Acquire (or create) the per-size lock so that concurrent requests
        // for the same volsize serialise through ensure_cache exactly once.
        let size_lock = {
            let mut map = self.format_locks.lock().await;
            map.entry(volsize)
                .or_insert_with(|| Arc::new(tokio::sync::Mutex::new(())))
                .clone()
        };
        let _guard = size_lock.lock().await;

        // Ensure the pre-formatted cache snapshot exists for this size.
        let cache_snap = ensure_cache(volsize).await?;

        // Clone the snapshot to produce the caller's zvol.
        // clone_snapshot is sync and drops NvList before the next await.
        clone_snapshot(&cache_snap, &target_dataset)?;

        // Wait for the cloned device node to appear under /dev/zvol/.
        wait_for_device(&target_device, Duration::from_secs(10)).await?;

        Ok(CreateFileSystemOutput {
            zvol: target_dataset,
            device: target_device,
            fs_type: "ext4".to_string(),
            size_bytes: volsize,
        })
    }

    /// Destroy the zvol identified by `id`.
    ///
    /// Uses `lzc_destroy`. Returns an error if the zvol does not exist.
    /// Cache zvols under `_cache/` are never touched by this activity.
    #[activity]
    pub async fn delete_file_system(
        _ctx: ActivityContext,
        input: DeleteFileSystemInput,
    ) -> Result<(), ActivityError> {
        validate_id(&input.id)?;

        let name = zvol_name(&input.id);

        lzc()?
            .destroy(name.as_str())
            .map_err(|e| anyhow::anyhow!("lzc_destroy('{}') failed: {e}", input.id).into())
    }
}
