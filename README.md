# fs-worker

A [Temporal](https://temporal.io/) activity worker written in Go for ZFS branch management. It listens on the `fs-worker` task queue and handles a single activity:

| Activity | Description |
|---|---|
| `InitBranch` | Creates a ZFS branch as either a zvol (block device) or a ZFS dataset (filesystem) |

---

## Base volume

The worker expects a pre-formatted base zvol and snapshot to exist before any `InitBranch` activity with mode `zvol` is dispatched. This is created once during host setup by `scripts/vm-setup.sh`:

```
<pool>/_base/             ZFS filesystem (parent)
<pool>/_base/vol          thin zvol, 1 GiB, formatted ext4
<pool>/_base/vol@empty    snapshot of the freshly-formatted zvol
```

When `InitBranch` is called with mode `zvol`, the branch is created by cloning `<pool>/_base/vol@empty` — no formatting happens at activity time.

When `InitBranch` is called with mode `zds`, a plain ZFS filesystem dataset is created directly — the base volume is not involved.

---

## Requirements

- Go 1.23+
- A running [Temporal](https://temporal.io/) server
- `zfs` CLI tool available in `$PATH` (part of `zfsutils-linux` on Ubuntu)
- The worker must run as a user with permission to execute ZFS commands (typically `root` or a user with appropriate ZFS delegation)
- The base volume (`<pool>/_base/vol@empty`) must exist before dispatching zvol branches (created by `make setup`)

---

## Configuration

All configuration is via environment variables:

| Variable | Default | Description |
|---|---|---|
| `TEMPORAL_HOST` | `localhost:7233` | Temporal frontend gRPC address |
| `TEMPORAL_NAMESPACE` | `default` | Temporal namespace |
| `TEMPORAL_TASK_QUEUE` | `fs-worker` | Task queue name |
| `ZFS_POOL` | `testpool` | ZFS pool to manage branches in |

---

## Building

```sh
go build -o fs-worker .
```

## Running

```sh
# With defaults (Temporal on localhost, testpool ZFS pool)
./fs-worker

# With custom configuration
TEMPORAL_HOST=temporal.example.com:7233 \
TEMPORAL_NAMESPACE=production \
ZFS_POOL=datapool \
./fs-worker
```

---

## Activity reference

### `InitBranch`

**Input**

```json
{
  "id": "my-branch",
  "mode": "zvol"
}
```

| Field | Type | Description |
|---|---|---|
| `id` | string | Unique identifier. Used as the dataset name under the pool. |
| `mode` | string | Branch backing type: `"zvol"` (block device, ext4) or `"zds"` (ZFS dataset). |

**ID validation rules**

- Must not be empty.
- Must not start with `_`.
- Must not contain `/` or `@`.
- May only contain alphanumerics and the characters `-`, `_`, `.`, `:`.

**Output (zvol mode)**

```json
{
  "dataset": "testpool/my-branch",
  "device": "/dev/zvol/testpool/my-branch",
  "fs_type": "ext4",
  "mode": "zvol"
}
```

**Output (zds mode)**

```json
{
  "dataset": "testpool/my-branch",
  "mount_point": "/testpool/my-branch",
  "fs_type": "zfs",
  "mode": "zds"
}
```

| Field | Type | Description |
|---|---|---|
| `dataset` | string | Fully-qualified ZFS dataset name. |
| `device` | string | Linux block-device path. Present only for zvol mode. |
| `mount_point` | string | ZFS mount point. Present only for zds mode. |
| `fs_type` | string | Filesystem type: `"ext4"` for zvol, `"zfs"` for zds. |
| `mode` | string | Echoes back the branch mode that was used. |

---

## ZFS pool layout

```
<pool>/
├── _base/                           ← created by vm-setup.sh
│   └── vol                          ← thin zvol, 1 GiB, formatted ext4
│       └── @empty                   ← snapshot (base for all zvol clones)
├── my-branch                        ← zvol clone of _base/vol@empty
└── another-branch                   ← zds (plain ZFS filesystem dataset)
```

The base volume under `_base/` is created once during host setup and is never modified at runtime.

---

## Project structure

```
fs-worker/
  main.go               Entrypoint: reads config, dials Temporal, registers activities, runs worker
  activities/
    types.go            Input/output structs and BranchMode constants
    zfs.go              ZFS helpers: naming, validation, CLI wrappers, device polling
    activities.go       FsWorkerActivities struct and InitBranch implementation
  go.mod
  go.sum
  scripts/              Deployment and VM management scripts
  Makefile              Make targets for all lifecycle operations
  README.md
  .gitignore
```

---

## Deployment modes

The scripts and Makefile support two target modes:

| Mode | When to use | How it works |
|---|---|---|
| **local** (default) | Day-to-day development on macOS | Provisions and targets a Multipass Ubuntu VM on your machine |
| **remote** | Staging / production on bare-metal | Connects to a Linux machine over SSH; AWS EC2 provisioning included |

Mode is auto-selected: once `REMOTE_HOST` is present in `.env` (written automatically by `make provision`), all scripts and `make` targets default to remote mode with no extra flags required. `--remote` / `REMOTE=1` exist as an explicit override for edge cases where you want to force remote mode without a `REMOTE_HOST` in `.env`.

---

## .env file

Create a `.env` file in the project root (it is gitignored). All scripts load it automatically.

### Local mode — no `.env` required

The only values you might want to override are the VM name and pool name:

```sh
# .env (all optional)
VM_NAME=zfs-dev       # Multipass VM name          (default: zfs-dev)
ZFS_POOL=testpool     # ZFS pool name               (default: testpool)
```

### Remote mode

```sh
# .env
REMOTE_HOST=1.2.3.4            # IP or hostname of the bare-metal machine (required)
REMOTE_USER=ubuntu             # SSH login user                            (default: ubuntu)
REMOTE_PEM=/path/to/key.pem    # Path to the SSH private key on your Mac  (required)
REMOTE_POOL_DEVICE=/dev/nvme1n1 # Block device for the ZFS pool on remote  (required)

# Optional
REMOTE_PORT=22
REMOTE_WORK_DIR=/home/worker/fs-worker
ZFS_POOL=testpool
TEMPORAL_HOST=http://localhost:7233
TEMPORAL_NAMESPACE=default
TEMPORAL_TASK_QUEUE=fs-worker
```

When `vm-provision.sh` is used to create an EC2 instance, it writes `REMOTE_HOST`,
`REMOTE_PEM`, `REMOTE_USER`, `REMOTE_WORK_DIR`, and `REMOTE_POOL_DEVICE` into `.env`
automatically — no manual editing required after provisioning.

---

## macOS prerequisites

Install these tools on your Mac before running any scripts:

```sh
brew install go              # Go toolchain (local builds)
brew install temporal        # Temporal CLI (server + smoke tests)
brew install multipass       # Multipass (local VM mode only)
brew install awscli          # AWS CLI    (remote EC2 mode only)
brew install jq              # JSON tool  (remote EC2 mode only)
```

---

## Quickstart — local mode (Multipass VM)

The local mode runs the worker inside a Multipass Ubuntu VM on your Mac. The project
directory is bind-mounted into the VM so edits are reflected immediately without an
explicit sync step.

#### 1 — Start a local Temporal server

```sh
temporal server start-dev
```

This starts Temporal on `localhost:7233` and opens the Web UI at `http://localhost:8233`.

#### 2 — Provision the VM (first time only)

```sh
make setup
# or: ./scripts/vm-setup.sh
```

This creates a Multipass VM (`zfs-dev`, 2 CPU / 4 GB RAM / 20 GB disk), installs ZFS and
Go, creates a loopback-backed ZFS pool (`testpool`), creates the pre-formatted base
volume (`_base/vol@empty`), mounts the project directory into the VM, and installs a
`fs-worker` systemd unit.

Pass `--recreate` / `make setup-recreate` to tear down and rebuild the VM from scratch.

#### 3 — Build inside the VM

```sh
make build           # debug build
make build-release   # optimised build
```

#### 4 — Run the worker

```sh
make run             # foreground — logs stream to your terminal
make run-detach      # background via systemd
make logs            # follow logs (works for both foreground and systemd)
```

#### 5 — Run smoke tests

```sh
make test
```

#### 6 — Stop everything

```sh
make stop            # stop worker + export ZFS pool + halt VM
make stop-service    # stop worker only, leave VM running
make suspend         # suspend the VM instead of shutting down
```

---

## Quickstart — remote mode (AWS EC2 bare-metal)

The remote mode targets a real Linux machine over SSH. The recommended instance type
is `a1.metal` (arm64 bare-metal) because ZFS benefits from direct hardware access and
avoids nested-virtualisation overhead.

### Step 1 — Authenticate with AWS

```sh
aws sso login
# or: export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
```

### Step 2 — Provision an EC2 instance (first time only)

```sh
make provision
# or: ./scripts/vm-provision.sh
```

`vm-provision.sh` is **idempotent** — re-running it safely skips steps that are already
done. It performs the following:

1. Creates (or reuses tagged) VPC, subnet, internet gateway, and route table.
2. Creates a security group with SSH (port 22) open only to your current public IP.
3. Resolves the latest Ubuntu 24.04 arm64 AMI from Canonical.
4. Launches an `a1.metal` instance with a 30 GB gp3 root volume and IMDSv2 enabled.
5. Allocates an Elastic IP and associates it with the instance so the public IP is
   stable across reboots.
6. Creates and attaches a separate EBS gp3 data volume (default: 20 GB) for the ZFS pool.
7. SSHes into the instance to detect the NVMe device name of the data volume and writes
   it as `REMOTE_POOL_DEVICE` in `.env`.
8. Writes `REMOTE_HOST`, `REMOTE_USER`, `REMOTE_PEM`, and `REMOTE_WORK_DIR` to `.env`.

After this step all other scripts and `make` targets work with no further configuration.

**Configurable variables** (set in `.env` or environment before running):

| Variable | Default | Description |
|---|---|---|
| `AWS_REGION` | `us-east-1` | AWS region |
| `AWS_PROFILE` | _(unset)_ | AWS CLI named profile |
| `AWS_INSTANCE_TYPE` | `a1.metal` | EC2 instance type |
| `AWS_EBS_SIZE_GB` | `20` | Size in GB of the ZFS data volume |
| `AWS_EBS_TYPE` | `gp3` | EBS volume type |
| `AWS_KEY_NAME` | `fs-worker` | EC2 key pair name — created automatically if absent |
| `AWS_PEM_PATH` | `~/.ssh/fs-worker.pem` | Local path to the PEM key — created automatically if absent |
| `AWS_VPC_ID` | _(auto)_ | Existing VPC to reuse — created and tagged if absent |
| `AWS_SUBNET_ID` | _(auto)_ | Existing subnet to reuse — created if absent |
| `AWS_SG_ID` | _(auto)_ | Existing security group — created if absent |
| `REMOTE_USER` | `ubuntu` | SSH login user on the instance |
| `REMOTE_WORK_DIR` | `/home/worker/fs-worker` | Project directory on the instance |
| `ZFS_POOL` | `testpool` | ZFS pool name |

### Step 3 — Start a local Temporal server

Run this on your Mac. The scripts set up a reverse SSH tunnel so the worker on the
remote host can reach Temporal at `localhost:7233`.

```sh
temporal server start-dev
```

### Step 4 — Provision the remote host (first time only)

```sh
make setup
# or: ./scripts/vm-setup.sh
```

The script connects over SSH and:

- Installs `zfsutils-linux`, `zfs-dkms`, and other required packages.
- Installs Go 1.23.6 from the official tarball under `/usr/local/go`.
- Creates the ZFS pool directly on the EBS block device (`REMOTE_POOL_DEVICE`).
- Creates the pre-formatted base volume (`_base/vol@empty`) for zvol branches.
- Enables the standard ZFS import services so the pool is automatically re-imported
  after a reboot.
- Syncs the project source to `REMOTE_WORK_DIR` via rsync.
- Installs a `fs-worker` systemd unit that starts the worker on boot.

### Step 5 — Build on the remote host

```sh
make build          # debug build
make build-release  # optimised build
```

The source is rsynced to the remote before every build.

### Step 6 — Run the worker

```sh
make run            # foreground — logs stream to your terminal
make run-detach     # background via systemd
make logs           # follow logs
```

### Step 7 — Forward the metrics port

The worker exposes Prometheus metrics on port `9090`. To scrape them locally
(e.g. for the monitoring stack), forward the port through SSH:

```sh
make port-forward-bg   # start tunnel in background (localhost:9090)
make port-forward-stop # stop it
```

> The reverse tunnel for Temporal (`-R`) is set up automatically by `vm-run.sh`
> when `TEMPORAL_HOST` in `.env` is `localhost` — no manual forwarding needed.

### Step 8 — Run smoke tests

```sh
make test
```

### Step 9 — Open a shell on the remote host

```sh
make shell       # SSH as REMOTE_USER
make shell-root  # SSH then sudo -i bash
```

### Step 10 — Stop the worker

```sh
make stop-service   # stop worker service, leave host running
make stop           # stop worker + export ZFS pool (host stays up)
```

> `make suspend` is not available in remote mode — there is no VM lifecycle to manage.

### Updating your IP in the security group

The security group's SSH rule is locked to the IP you had when `vm-provision.sh` ran.
If your IP changes (different network, VPN, ISP reassignment) all SSH-based operations
will time out. Fix it with:

```sh
make ssh-allow
# or: ./scripts/vm-ssh-allow.sh
```

### Tearing everything down

```sh
make provision-destroy
# or: ./scripts/vm-provision.sh --destroy
```

This terminates the EC2 instance, deletes the EBS data volume, releases the Elastic IP,
deletes the security group, and removes all `REMOTE_*` and `AWS_*` entries from `.env`.
The VPC and subnet are left in place (they are cheap) but are tagged and will be reused
on the next `make provision` run.

---

## Makefile reference

```sh
make help   # print all available targets
```

| Target | Description |
|---|---|
| `make setup` | Provision and configure the target (VM or remote host) |
| `make setup-recreate` | Recreate the local Multipass VM from scratch |
| `make provision` | Launch an AWS EC2 a1.metal instance + EBS ZFS volume |
| `make provision-destroy` | Terminate the EC2 instance and delete AWS resources |
| `make ssh-allow` | Update EC2 security group with your current IP |
| `make build` | Build the worker binary on the target (debug) |
| `make build-release` | Build with optimisations |
| `make build-local` | Build the binary locally (requires Go 1.23+) |
| `make run` | Start the worker in the foreground |
| `make run-detach` | Start the worker as a background systemd service |
| `make stop` | Stop the worker and shut down / export the pool |
| `make stop-service` | Stop the worker service only |
| `make suspend` | Suspend the local Multipass VM |
| `make logs` | Follow worker logs |
| `make test` | Run smoke tests against the running worker |
| `make shell` | Open an interactive shell on the target |
| `make shell-root` | Open a root shell on the target |
| `make port-forward` | Forward Temporal port to localhost:7233 (foreground) |
| `make port-forward-bg` | Forward Temporal port in the background |
| `make port-forward-stop` | Stop a background port-forward tunnel |
| `make fmt` | Run `gofmt` across all Go source files |
| `make vet` | Run `go vet` |
| `make tidy` | Run `go mod tidy` |
| `make clean` | Remove the locally-built binary |

Once `REMOTE_HOST` is set in `.env`, all targets automatically target the remote host.
`REMOTE=1` is available as an explicit override if you need to force remote mode without
`REMOTE_HOST` being set:

```sh
make build REMOTE=1
```

---

## Monitoring

The worker exposes a Prometheus metrics endpoint on port `9090` (configurable via
`METRICS_ADDR`). The port-forward script tunnels this alongside the Temporal port
so you can scrape metrics locally.

### Start the monitoring stack

```sh
cd monitoring
docker compose up -d
```

This starts:

| Service    | URL                        | Credentials   |
|------------|----------------------------|---------------|
| Grafana    | http://localhost:3000       | admin / admin |
| Prometheus | http://localhost:9091       | —             |

### Configure Grafana

1. Open Grafana at http://localhost:3000
2. Go to **Connections → Data sources → Add data source**
3. Select **Prometheus**, set URL to `http://prometheus:9090`, click **Save & test**
4. Create a dashboard or explore metrics like `temporal_activity_execution_latency`

### Stop the monitoring stack

```sh
cd monitoring
docker compose down
```

## Scripts reference

Every script except `vm-provision.sh` and `vm-ssh-allow.sh` accepts `--remote` to
force remote mode regardless of `.env`. This is rarely needed — once `REMOTE_HOST` is
set in `.env` remote mode is selected automatically.

| Script | Description |
|---|---|
| `scripts/vm-provision.sh` | Create (or destroy) the AWS EC2 instance + EBS volume; writes `.env` |
| `scripts/vm-ssh-allow.sh` | Update the EC2 security group SSH rule to your current public IP |
| `scripts/vm-setup.sh` | Provision the target: ZFS, Go, base volume, systemd units |
| `scripts/vm-build.sh` | Build fs-worker on the target (rsyncs source first in remote mode) |
| `scripts/vm-run.sh` | Start the worker (foreground or `--detach` for systemd) |
| `scripts/vm-stop.sh` | Stop the worker and optionally the VM / pool |
| `scripts/vm-logs.sh` | Tail fs-worker logs from journald or stdout |
| `scripts/vm-shell.sh` | Open an interactive shell on the target |
| `scripts/vm-port-forward.sh` | SSH tunnel `localhost:9090` (metrics) ↔ target |
| `scripts/vm-test.sh` | Smoke tests: server health + task queue registration |