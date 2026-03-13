use std::ffi::CString;
use std::time::Duration;

use tonic::{Request, Response, Status};

use crate::worker_proto::{
    CreateFileSystemRequest, CreateFileSystemResponse, DeleteFileSystemRequest,
    DeleteFileSystemResponse, worker_server::Worker,
};

use zfs_core::DataSetType;

/// Default zvol size: 1 GiB.
const DEFAULT_VOLSIZE: u64 = 1 * 1024 * 1024 * 1024;

/// ZFS pool name — overridable at runtime via the `ZFS_POOL` environment variable.
fn pool() -> String {
    std::env::var("ZFS_POOL").unwrap_or_else(|_| "testpool".to_string())
}

/// Fully-qualified zvol dataset name for a given id: `<pool>/<id>`.
fn zvol_name(id: &str) -> String {
    format!("{}/{}", pool(), id)
}

/// Linux block device path for a zvol: `/dev/zvol/<pool>/<id>`.
fn zvol_device(id: &str) -> String {
    format!("/dev/zvol/{}/{}", pool(), id)
}

/// Open a [`zfs_core::Zfs`] handle.
fn lzc() -> Result<zfs_core::Zfs, Status> {
    zfs_core::Zfs::new().map_err(|e| Status::internal(format!("libzfs_core init failed: {e}")))
}

/// Validate that an `id` is safe to use as a ZFS dataset name component.
/// ZFS names may only contain alphanumerics, hyphens, underscores, periods,
/// and colons. An empty id or one starting with a digit is also rejected.
fn validate_id(id: &str) -> Result<(), Status> {
    if id.is_empty() {
        return Err(Status::invalid_argument("id must not be empty"));
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

/// Run an external command on a dedicated blocking thread, returning its
/// stdout on success or a [`Status::internal`] error containing stderr on
/// failure.
///
/// `spawn_blocking` is used so that the synchronous `std::process::Command`
/// call does not block the async executor thread.
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
                stderr.trim()
            )))
        }
    })
    .await
    .map_err(|e| Status::internal(format!("spawn_blocking panicked: {e}")))?
}

/// Wait for the kernel to expose the zvol block device, retrying up to
/// `max_wait`. The device is created asynchronously by the ZFS kernel module
/// after `lzc_create` returns, so a short retry loop is necessary.
async fn wait_for_device(device: &str, max_wait: Duration) -> Result<(), Status> {
    let interval = Duration::from_millis(200);
    let mut elapsed = Duration::ZERO;

    loop {
        if tokio::fs::metadata(device).await.is_ok() {
            return Ok(());
        }
        if elapsed >= max_wait {
            return Err(Status::internal(format!(
                "timed out waiting for block device {device} to appear after {max_wait:?}"
            )));
        }
        tokio::time::sleep(interval).await;
        elapsed += interval;
    }
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

#[derive(Debug, Default)]
pub struct ZfsService;

#[tonic::async_trait]
impl Worker for ZfsService {
    /// Create a ZFS zvol named `<pool>/<id>`, then format it with ext4.
    ///
    /// Steps:
    ///   1. Validate the id.
    ///   2. Create the zvol via `lzc_create` (zfs-core).
    ///   3. Wait for the kernel to expose `/dev/zvol/<pool>/<id>`.
    ///   4. Run `mkfs.ext4` on the device.
    async fn create_file_system(
        &self,
        request: Request<CreateFileSystemRequest>,
    ) -> Result<Response<CreateFileSystemResponse>, Status> {
        let req = request.into_inner();
        validate_id(&req.id)?;

        let name = zvol_name(&req.id);
        let device = zvol_device(&req.id);
        let size_bytes = if req.size_bytes == 0 {
            DEFAULT_VOLSIZE
        } else {
            req.size_bytes
        };

        // ── 1. Create the zvol ────────────────────────────────────────────
        // `volsize` is a required property for zvols; it must be a multiple of
        // the volblocksize (default 8 KiB). Round up to the nearest 8 KiB.
        const BLOCK_SIZE: u64 = 8 * 1024;
        let volsize = (size_bytes + BLOCK_SIZE - 1) / BLOCK_SIZE * BLOCK_SIZE;

        // props is scoped to this block so it is dropped before the first
        // `.await` point below. nvpair::NvList holds a raw pointer and is not
        // Send, so it must not be held across an await.
        {
            let mut props = nvpair::NvList::new();

            // nvpair 0.5 does not implement NvEncode for u64, so we call the
            // underlying libnvpair FFI directly for all uint64 properties.
            let volsize_key = CString::new("volsize")
                .map_err(|e| Status::internal(format!("CString::new failed: {e}")))?;
            let rc = unsafe {
                nvpair_sys::nvlist_add_uint64(props.as_mut_ptr(), volsize_key.as_ptr(), volsize)
            };
            if rc != 0 {
                return Err(Status::internal(format!(
                    "nvlist_add_uint64(volsize) failed with code {rc}"
                )));
            }

            // Thin provisioning: set refreservation=0 so ZFS does not
            // pre-allocate space equal to the zvol size. Equivalent to
            // `zfs create -s`.
            let refreservation_key = CString::new("refreservation")
                .map_err(|e| Status::internal(format!("CString::new failed: {e}")))?;
            let rc = unsafe {
                nvpair_sys::nvlist_add_uint64(props.as_mut_ptr(), refreservation_key.as_ptr(), 0)
            };
            if rc != 0 {
                return Err(Status::internal(format!(
                    "nvlist_add_uint64(refreservation) failed with code {rc}"
                )));
            }

            lzc()?
                .create(&name, DataSetType::Zvol, &props)
                .map_err(|e| {
                    if e.raw_os_error() == Some(libc::EEXIST) {
                        Status::already_exists(format!(
                            "filesystem '{id}' already exists",
                            id = req.id
                        ))
                    } else {
                        Status::internal(format!("lzc_create failed: {e}"))
                    }
                })?;
        } // props dropped here — safe to .await below

        // ── 2. Wait for the block device to appear ────────────────────────
        wait_for_device(&device, Duration::from_secs(10)).await?;

        // ── 3. Format with ext4 ───────────────────────────────────────────
        // -F                          : force (non-interactive)
        // -L                          : set filesystem label to the id
        // -E lazy_itable_init=0       : zero inode tables now, not lazily in
        //                               the background after mount; does NOT
        //                               increase total bytes written — it only
        //                               moves those writes to format time so
        //                               actual disk usage is fully settled when
        //                               this RPC returns.
        // -E lazy_journal_init=0      : same reasoning for the journal area.
        // mkfs.ext4 is CPU-bound and blocking; run it on a dedicated thread.
        let mkfs_args = vec![
            "-F".to_string(),
            "-L".to_string(),
            req.id.clone(),
            "-E".to_string(),
            "lazy_itable_init=0,lazy_journal_init=0".to_string(),
            device.clone(),
        ];
        run_blocking("mkfs.ext4", mkfs_args).await.map_err(|e| {
            // Best-effort cleanup: destroy the zvol so the caller can retry.
            // We ignore errors here since we're already in an error path.
            let name_clone = name.clone();
            tokio::spawn(async move {
                if let Ok(z) = zfs_core::Zfs::new() {
                    let _ = z.destroy(name_clone.as_str());
                }
            });
            e
        })?;

        Ok(Response::new(CreateFileSystemResponse {
            zvol: name,
            device,
            fs_type: "ext4".to_string(),
            size_bytes: volsize,
        }))
    }

    /// Destroy the zvol (and its block device) identified by `id`.
    ///
    /// Uses `lzc_destroy` from `libzfs_core`. Returns NOT_FOUND if the zvol
    /// does not exist.
    async fn delete_file_system(
        &self,
        request: Request<DeleteFileSystemRequest>,
    ) -> Result<Response<DeleteFileSystemResponse>, Status> {
        let req = request.into_inner();
        validate_id(&req.id)?;

        let name = zvol_name(&req.id);

        lzc()?.destroy(name.as_str()).map_err(|e| {
            if e.raw_os_error() == Some(libc::ENOENT) {
                Status::not_found(format!("filesystem '{id}' not found", id = req.id))
            } else {
                Status::internal(format!("lzc_destroy failed: {e}"))
            }
        })?;

        Ok(Response::new(DeleteFileSystemResponse {}))
    }
}
