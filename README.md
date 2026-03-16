# fs-worker

A [Temporal](https://temporal.io) activity worker that manages ZFS-backed ext4 filesystems.
Each filesystem is a thin-provisioned ZFS zvol formatted with ext4. A per-size snapshot cache
means `mkfs.ext4` runs at most once per distinct volume size — subsequent creates are
near-instant ZFS clones.

## Activities

### `create_file_system`

Creates a ZFS zvol named `<pool>/<id>`, formatted with ext4.

**Input**
```json
{
  "id": "my-fs",
  "size_bytes": 1073741824
}
```

| Field        | Type   | Required | Description                                              |
|--------------|--------|----------|----------------------------------------------------------|
| `id`         | string | yes      | Unique identifier. Becomes the zvol name under the pool. |
| `size_bytes` | uint64 | no       | Zvol size in bytes. Defaults to 1 GiB when `0` or omitted. Rounded up to the nearest 8 KiB boundary. |

**Output**
```json
{
  "zvol": "testpool/my-fs",
  "device": "/dev/zvol/testpool/my-fs",
  "fs_type": "ext4",
  "size_bytes": 1073741824
}
```

**How it works**

```
First call for a given size (slow path — runs mkfs.ext4 once):
  1. Create testpool/_cache/<size>        thin zvol
  2. mkfs.ext4 on /dev/zvol/testpool/_cache/<size>
  3. zfs snapshot testpool/_cache/<size>@formatted
  4. zfs clone   testpool/_cache/<size>@formatted → testpool/<id>

All subsequent calls for the same size (fast path — ZFS clone only):
  4. zfs clone   testpool/_cache/<size>@formatted → testpool/<id>
```

---

### `delete_file_system`

Destroys the zvol identified by `id`. The `_cache` zvols are never touched.

**Input**
```json
{
  "id": "my-fs"
}
```

| Field | Type   | Required | Description                          |
|-------|--------|----------|--------------------------------------|
| `id`  | string | yes      | Identifier passed to `create_file_system`. |

**Output** — empty on success.

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Temporal Server  (localhost:7233)               │
└──────────────────────────┬──────────────────────┘
                           │  task queue: fs-worker
                           ▼
┌─────────────────────────────────────────────────┐
│  fs-worker  (this binary)                        │
│                                                  │
│  FsWorkerActivities                              │
│  ├── create_file_system                          │
│  │     ├── ensure_cache(volsize)                 │
│  │     │     ├── lzc_create  (_cache zvol)       │
│  │     │     ├── mkfs.ext4   (blocking thread)   │
│  │     │     └── lzc_snapshot (@formatted)       │
│  │     └── lzc_clone  (snapshot → testpool/<id>) │
│  └── delete_file_system                          │
│        └── lzc_destroy (testpool/<id>)           │
│                                                  │
│  ZFS pool layout                                 │
│  testpool/                                       │
│  ├── _cache/                                     │
│  │   └── 1073741824/        ← one per size       │
│  │       └── @formatted     ← cache snapshot     │
│  ├── my-fs                  ← clone              │
│  └── another-fs             ← clone              │
└─────────────────────────────────────────────────┘
```

---

## Prerequisites

### macOS (development)

- [Multipass](https://multipass.run) — `brew install multipass`
- [Temporal CLI](https://docs.temporal.io/cli) — `brew install temporal`
- Rust stable — installed automatically by `scripts/vm-setup.sh` inside the VM

### Linux VM

The worker must run on a Linux host with ZFS kernel support. The provided scripts
automate everything using a Multipass Ubuntu 24.04 VM.

---

## Quickstart

### 1 — Start a local Temporal server (on your Mac)

```bash
temporal server start-dev
```

This starts Temporal on `localhost:7233` and opens the Web UI at `http://localhost:8233`.

---

### 2 — Provision the VM (first time only)

```bash
./scripts/vm-setup.sh
```

This will:
- Create a Multipass VM named `zfs-dev` (2 CPU, 4 GB RAM, 20 GB disk)
- Install ZFS kernel module and userland tools
- Install Rust stable and all C build dependencies
- Create a 512 MB loopback-backed ZFS pool called `testpool`
- Mount the project directory into the VM at `/home/ubuntu/worker`
- Install systemd units for pool persistence and the worker service

> Pass `--recreate` to tear down and rebuild the VM from scratch.

---

### 3 — Build inside the VM

```bash
./scripts/vm-build.sh           # debug build (default)
./scripts/vm-build.sh --release # release build
```

---

### 4 — Run the worker

**Foreground** (logs stream to your terminal):

```bash
./scripts/vm-run.sh
```

**Background** (managed by systemd):

```bash
./scripts/vm-run.sh --detach
./scripts/vm-logs.sh            # follow logs
```

Pass `--rebuild` to build before starting:

```bash
./scripts/vm-run.sh --rebuild --release
```

---

### 5 — Forward the Temporal port (optional)

If your workflow code runs on the Mac and needs to reach the Temporal server
from inside the VM, or vice versa, use the port-forward script:

```bash
./scripts/vm-port-forward.sh --background   # tunnel localhost:50051 ↔ VM
./scripts/vm-port-forward.sh --stop         # tear it down
```

---

### 6 — Smoke-test the activities

Install `grpcurl` if you haven't already, then run the test suite:

```bash
brew install grpcurl
./scripts/vm-test.sh
```

To run tests entirely from inside the VM (no tunnel needed):

```bash
./scripts/vm-test.sh --via-vm
```

---

### 7 — Stop everything

```bash
./scripts/vm-stop.sh                 # stop worker + export ZFS pool + halt VM
./scripts/vm-stop.sh --service-only  # stop worker only, leave VM running
./scripts/vm-stop.sh --suspend       # suspend VM instead of shutting down
```

---

## Other helper scripts

| Script | Description |
|---|---|
| `scripts/vm-setup.sh` | Provision the VM (first-time setup) |
| `scripts/vm-build.sh` | Compile the worker inside the VM |
| `scripts/vm-run.sh` | Start the worker (foreground or `--detach`) |
| `scripts/vm-stop.sh` | Stop the worker and/or VM |
| `scripts/vm-logs.sh` | Tail worker logs from journald |
| `scripts/vm-shell.sh` | Open an interactive shell in the VM |
| `scripts/vm-port-forward.sh` | SSH tunnel for gRPC port forwarding |
| `scripts/vm-test.sh` | End-to-end smoke tests against a running worker |

---

## Configuration

All configuration is via environment variables. The defaults work for local development.

| Variable | Default | Description |
|---|---|---|
| `TEMPORAL_HOST` | `http://localhost:7233` | Temporal server address |
| `TEMPORAL_NAMESPACE` | `default` | Temporal namespace |
| `TEMPORAL_TASK_QUEUE` | `fs-worker` | Task queue the worker listens on |
| `TEMPORAL_DEPLOYMENT_NAME` | `fs-worker` | Deployment name for versioning |
| `BUILD_ID` | crate version | Build ID (can be set at compile time via `BUILD_ID` env var) |
| `ZFS_POOL` | `testpool` | ZFS pool to create zvols in |
| `RUST_LOG` | `info` | Log level filter (e.g. `debug`, `fs_worker=trace`) |

### Example: point the worker at a non-default Temporal namespace

```bash
TEMPORAL_HOST=http://temporal.internal:7233 \
TEMPORAL_NAMESPACE=production \
TEMPORAL_TASK_QUEUE=fs-worker-prod \
ZFS_POOL=datapool \
./target/release/fs-worker
```

---

## ZFS pool layout

```
<pool>/
├── _cache/                         ← parent filesystem, created automatically
│   ├── 1073741824/                 ← thin zvol, one entry per distinct size (bytes)
│   │   └── @formatted              ← pre-formatted ext4 snapshot (cache key)
│   └── 2147483648/
│       └── @formatted
├── my-filesystem                   ← clone of _cache/1073741824@formatted
└── another-filesystem              ← clone of _cache/1073741824@formatted
```

Cache zvols are **never deleted** by `delete_file_system`. They accumulate one entry
per distinct `size_bytes` value seen across all `create_file_system` calls and persist
for the lifetime of the pool.

---

## id constraints

The `id` field used in both activities must satisfy:

- Non-empty
- Does **not** start with `_` (reserved for internal datasets like `_cache`)
- Does **not** contain `/` or `@`
- Contains only: `a–z A–Z 0–9 - _ . :`

---

## Building from source (without the VM scripts)

Requires a Linux host with ZFS installed (`zfsutils-linux`, `libzfs-dev`, `libclang-dev`).

```bash
cargo build --release
```

The binary will be at `target/release/fs-worker`.
```

Now let's write it to disk and commit: