# =============================================================================
# fs-worker Makefile
#
# All targets that interact with a remote/VM target delegate to the scripts
# in scripts/. Set REMOTE=1 to target the bare-metal SSH host from .env.
#
# Usage:
#   make setup             Provision and set up the target (VM or remote host)
#   make build             Build the fs-worker binary on the target
#   make run               Start the worker in the foreground
#   make run-detach        Start the worker as a background systemd service
#   make stop              Stop the worker (and optionally the VM)
#   make stop-service      Stop only the worker service, leave the host running
#   make logs              Tail the worker logs
#   make test              Run smoke tests against the running worker
#   make shell             Open an interactive shell on the target
#   make port-forward      Forward the Temporal port to localhost:7233
#   make port-forward-stop Stop a background port-forward tunnel
#   make provision         Provision an AWS EC2 instance + EBS volume
#   make provision-destroy Destroy the EC2 instance and associated resources
#   make ssh-allow         Update the EC2 security group with your current IP
#
# Local development (no target):
#   make build-local       Build the binary locally (requires Go 1.23+)
#   make fmt               Run gofmt across the codebase
#   make vet               Run go vet
#   make tidy              Run go mod tidy
#   make clean             Remove the locally-built binary
# =============================================================================

SCRIPTS := scripts

# Pass --remote to every script when REMOTE=1 is set on the command line.
# e.g.:  make build REMOTE=1
ifdef REMOTE
_REMOTE_FLAG := --remote
else
_REMOTE_FLAG :=
endif

.PHONY: setup build build-local run run-detach stop stop-service logs test \
        shell port-forward port-forward-stop provision provision-destroy \
        ssh-allow fmt vet tidy clean help

# ---------------------------------------------------------------------------
# Target provisioning
# ---------------------------------------------------------------------------

## setup: Provision the target (VM or bare-metal): ZFS, Go, systemd units
setup:
	$(SCRIPTS)/vm-setup.sh $(_REMOTE_FLAG)

## setup-recreate: Recreate the local Multipass VM from scratch
setup-recreate:
	$(SCRIPTS)/vm-setup.sh --recreate

## setup-fc-init: Only recreate the ext4 rootfs (re-bake _fc_init.sh)
setup-fc-init:
	$(SCRIPTS)/vm-setup.sh $(_REMOTE_FLAG) --only-fc-init

## provision: Provision an AWS EC2 a1.metal instance + EBS ZFS volume
provision:
	$(SCRIPTS)/vm-provision.sh

## provision-destroy: Terminate the EC2 instance and delete AWS resources
provision-destroy:
	$(SCRIPTS)/vm-provision.sh --destroy

## ssh-allow: Update EC2 security group to allow SSH from your current IP
ssh-allow:
	$(SCRIPTS)/vm-ssh-allow.sh

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

## build: Build the fs-worker binary on the target (debug mode)
build:
	$(SCRIPTS)/vm-build.sh $(_REMOTE_FLAG)

## build-release: Build the fs-worker binary on the target (release mode)
build-release:
	$(SCRIPTS)/vm-build.sh $(_REMOTE_FLAG) --release

## build-clean: Remove previous binary then build on the target
build-clean:
	$(SCRIPTS)/vm-build.sh $(_REMOTE_FLAG) --clean

## build-local: Build the fs-worker binary locally (requires Go 1.23+)
build-local:
	go build -o fs-worker .

## build-local-release: Build locally with full optimisations
build-local-release:
	go build -ldflags="-s -w" -o fs-worker .

# ---------------------------------------------------------------------------
# Run / stop
# ---------------------------------------------------------------------------

## run: Start the worker in the foreground on the target
run:
	$(SCRIPTS)/vm-run.sh $(_REMOTE_FLAG)

## run-release: Start the release binary in the foreground
run-release:
	$(SCRIPTS)/vm-run.sh $(_REMOTE_FLAG) --release

## run-detach: Start the worker as a background systemd service
run-detach:
	$(SCRIPTS)/vm-run.sh $(_REMOTE_FLAG) --detach

## run-detach-release: Start the release binary as a background systemd service
run-detach-release:
	$(SCRIPTS)/vm-run.sh $(_REMOTE_FLAG) --release --detach

## stop: Stop the worker service and shut down the VM (local) or stop the service (remote)
stop:
	$(SCRIPTS)/vm-stop.sh $(_REMOTE_FLAG)

## stop-service: Stop only the worker service, leave the host running
stop-service:
	$(SCRIPTS)/vm-stop.sh $(_REMOTE_FLAG) --service-only

## suspend: Suspend the local Multipass VM (local mode only)
suspend:
	$(SCRIPTS)/vm-stop.sh --suspend

# ---------------------------------------------------------------------------
# Observe
# ---------------------------------------------------------------------------

## logs: Tail the worker logs (follows by default)
logs:
	$(SCRIPTS)/vm-logs.sh $(_REMOTE_FLAG)

## logs-n: Print the last N lines without following (make logs-n N=100)
logs-n:
	$(SCRIPTS)/vm-logs.sh $(_REMOTE_FLAG) --no-follow --lines $(or $(N),50)

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

## test: Run smoke tests against the running worker
test:
	$(SCRIPTS)/vm-test.sh

# ---------------------------------------------------------------------------
# Shell access
# ---------------------------------------------------------------------------

## shell: Open an interactive shell on the target
shell:
	$(SCRIPTS)/vm-shell.sh $(_REMOTE_FLAG)

## shell-root: Open a root shell on the target
shell-root:
	$(SCRIPTS)/vm-shell.sh $(_REMOTE_FLAG) --root

# ---------------------------------------------------------------------------
# Port forwarding
# ---------------------------------------------------------------------------

## port-forward: Forward Temporal port (localhost:7233 <-> target)
port-forward:
	$(SCRIPTS)/vm-port-forward.sh $(_REMOTE_FLAG)

## port-forward-bg: Forward Temporal port in the background
port-forward-bg:
	$(SCRIPTS)/vm-port-forward.sh $(_REMOTE_FLAG) --background

## port-forward-stop: Stop a background port-forward tunnel
port-forward-stop:
	$(SCRIPTS)/vm-port-forward.sh $(_REMOTE_FLAG) --stop

# ---------------------------------------------------------------------------
# Local Go tooling
# ---------------------------------------------------------------------------

## fmt: Format all Go source files
fmt:
	gofmt -w .

## vet: Run go vet on all packages
vet:
	go vet ./...

## tidy: Run go mod tidy
tidy:
	go mod tidy

## clean: Remove the locally-built binary
clean:
	rm -f fs-worker

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

## help: Print this help message
help:
	@echo ""
	@echo "fs-worker — Makefile targets"
	@echo ""
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /' | column -t -s ':'
	@echo ""
	@echo "  Remote mode is selected automatically when REMOTE_HOST is set in .env."
	@echo "  REMOTE=1 is available as an explicit override (rarely needed)."
	@echo ""
