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

## Modes

The scripts support two target modes:

| Mode | When to use | How it works |
|---|---|---|
| **local** (default) | Day-to-day development on macOS | Provisions and targets a Multipass Ubuntu VM |
| **remote** | Bare-metal development / staging | Connects to a Linux machine over SSH using credentials from `.env` |

Mode is auto-selected: if `REMOTE_HOST` is present in `.env`, all scripts default to remote mode. You can also pass `--remote` explicitly to any script to override.

---

## .env setup

Create a `.env` file in the project root (it is gitignored). A fully annotated template is provided:

```bash
cp .env.example .env
```

### Local mode (default — no `.env` required)

```bash
# .env (optional overrides)
VM_NAME=zfs-dev
ZFS_POOL=testpool
```

### Remote mode

```bash
# .env
REMOTE_HOST=1.2.3.4          # IP or hostname of the bare-metal machine
REMOTE_USER=ubuntu           # SSH login user
REMOTE_PEM=/path/to/key.pem  # Path to the PEM private key on your Mac

# Optional
REMOTE_PORT=22
REMOTE_WORK_DIR=/home/ubuntu/fs-worker
ZFS_POOL=testpool
```

Once `REMOTE_HOST` is set, all scripts automatically target the remote machine — no need to pass `--remote` explicitly.

---

## Prerequisites

### macOS (development)

- [Multipass](https://multipass.run) — `brew install multipass`
- [Temporal CLI](https://docs.temporal.io/cli) — `brew install temporal`
- Rust stable — installed automatically by `scripts/vm-setup.sh` inside the VM

### Linux target

The worker must run on a Linux host with ZFS kernel support. The provided scripts automate provisioning for both a local Multipass VM and a remote bare-metal machine.

---

## Quickstart

### Local mode (Multipass VM)

#### 1 — Start a local Temporal server (on your Mac)

```bash
temporal server start-dev
```

This starts Temporal on `localhost:7233` and opens the Web UI at `http://localhost:8233`.

---

#### 2 — Provision the VM (first time only)

```bash
./scripts/vm-setup.sh
```

This will:
- Create a Multipass VM named `zfs-dev` (2 CPU, 4 GB RAM, 20 GB disk)
- Install ZFS kernel module and userland tools
- Install Rust stable and all C build dependencies
- Create a 512 MB loopback-backed ZFS pool called `testpool`
- Mount the project directory into the VM at `/home/ubuntu/fs-worker`
- Install systemd units for pool persistence and the worker service

> Pass `--recreate` to tear down and rebuild the VM from scratch.

---

#### 3 — Build inside the VM

```bash
./scripts/vm-build.sh           # debug build (default)
./scripts/vm-build.sh --release # release build
```

---

#### 4 — Run the worker

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

#### 5 — Forward the Temporal port (optional)

Tunnel `localhost:7233` on your Mac to the Temporal server inside the VM:

```bash
./scripts/vm-port-forward.sh --background   # tunnel localhost:7233 ↔ VM
./scripts/vm-port-forward.sh --stop         # tear it down
```

---

#### 6 — Stop everything

```bash
./scripts/vm-stop.sh                 # stop worker + export ZFS pool + halt VM
./scripts/vm-stop.sh --service-only  # stop worker only, leave VM running
./scripts/vm-stop.sh --suspend       # suspend VM instead of shutting down
```

---

### Remote mode (bare-metal SSH)

#### 1 — Configure `.env`

```bash
cp .env.example .env
# Edit .env and set REMOTE_HOST, REMOTE_USER, REMOTE_PEM
```

#### 2 — Start a local Temporal server (on your Mac)

```bash
temporal server start-dev
```

#### 3 — Provision the remote host (first time only)

```bash
./scripts/vm-setup.sh
```

The script detects `REMOTE_HOST` in `.env` and runs over SSH. It will:
- Install ZFS kernel module and userland tools
- Install Rust stable and all C build dependencies
- Create a loopback-backed ZFS pool
- Sync the project source to `REMOTE_WORK_DIR`
- Install systemd units for pool persistence and the worker service

---

#### 4 — Build on the remote host

```bash
./scripts/vm-build.sh           # syncs source, then cargo build (debug)
./scripts/vm-build.sh --release # release build
```

The source is rsynced to the remote before every build.

---

#### 5 — Run the worker

**Foreground:**

```bash
./scripts/vm-run.sh
```

**Background (systemd):**

```bash
./scripts/vm-run.sh --detach
./scripts/vm-logs.sh            # follow journald logs
```

---

#### 6 — Forward the Temporal port

Tunnel `localhost:7233` on your Mac to the Temporal server on the remote host:

```bash
./scripts/vm-port-forward.sh --background
./scripts/vm-port-forward.sh --stop
```

---

#### 7 — Open a shell on the remote host

```bash
./scripts/vm-shell.sh           # SSH as REMOTE_USER
./scripts/vm-shell.sh --root    # SSH then sudo -i bash
```

---

#### 8 — Stop the worker

```bash
./scripts/vm-stop.sh                 # stop worker + export ZFS pool
./scripts/vm-stop.sh --service-only  # stop worker only
```

> `--suspend` is not available in remote mode (there is no VM lifecycle to manage).

---

## Scripts reference

Every script accepts `--remote` to target the bare-metal host regardless of `.env`.

| Script | Description |
|---|---|
| `scripts/vm-setup.sh` | Provision the target (VM or bare-metal) |
| `scripts/vm-build.sh` | Compile fs-worker on the target (rsyncs source in remote mode) |
| `scripts/vm-run.sh` | Start the worker (foreground or `--detach` for systemd) |
| `scripts/vm-stop.sh` | Stop the worker and optionally the VM |
| `scripts/vm-logs.sh` | Tail fs-worker logs from journald or stdout |
| `scripts/vm-shell.sh` | Open an interactive shell on the target |
| `scripts/vm-port-forward.sh` | SSH tunnel `localhost:7233` ↔ target |
| `scripts/vm-test.sh` | End-to-end smoke tests against a running worker |

---

## Configuration

### Script configuration (`.env` / environment)

All script behaviour is controlled via `.env` in the project root or environment variables.

| Variable | Default | Description |
|---|---|---|
| `REMOTE_HOST` | _(unset)_ | IP/hostname of the bare-metal target. Setting this activates remote mode. |
| `REMOTE_USER` | `ubuntu` | SSH login user |
| `REMOTE_PEM` | _(unset)_ | Path to the PEM private key on your Mac |
| `REMOTE_PORT` | `22` | SSH port |
| `REMOTE_WORK_DIR` | `/home/ubuntu/fs-worker` | Project directory on the remote host |
| `VM_NAME` | `zfs-dev` | Multipass VM name (local mode only) |
| `VM_MOUNT_PATH` | `/home/ubuntu/fs-worker` | Mount path inside the VM (local mode only) |
| `ZFS_POOL` | `testpool` | ZFS pool name used by the worker and scripts |

### Worker process configuration

| Variable | Default | Description |
|---|---|---|
| `TEMPORAL_HOST` | `http://localhost:7233` | Temporal server address |
| `TEMPORAL_NAMESPACE` | `default` | Temporal namespace |
| `TEMPORAL_TASK_QUEUE` | `fs-worker` | Task queue the worker listens on |
| `TEMPORAL_DEPLOYMENT_NAME` | `fs-worker` | Deployment name for versioning |
| `BUILD_ID` | crate version | Build ID (set at compile time via `BUILD_ID` env var) |
| `ZFS_POOL` | `testpool` | ZFS pool to create zvols in |
| `RUST_LOG` | `info` | Log level filter (e.g. `debug`, `fs_worker=trace`) |

### Example: remote bare-metal with non-default Temporal namespace

```bash
# .env
REMOTE_HOST=10.0.1.50
REMOTE_USER=ubuntu
REMOTE_PEM=~/.ssh/my-server.pem
ZFS_POOL=datapool
TEMPORAL_HOST=http://10.0.1.50:7233
TEMPORAL_NAMESPACE=staging
TEMPORAL_TASK_QUEUE=fs-worker-staging
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