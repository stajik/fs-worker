#!/usr/bin/env bash
# =============================================================================
# vm-test.sh — Smoke-test every gRPC endpoint of the worker service
#
# Requires grpcurl to be installed on the host Mac:
#   brew install grpcurl
#
# Usage:
#   ./scripts/vm-test.sh [--host <host>] [--port <port>] [--pool <pool>]
#
#   --host <h>   gRPC host to target (default: localhost)
#   --port <p>   gRPC port to target (default: 50051)
#   --pool <p>   ZFS pool name to use in tests (default: testpool)
#   --via-vm     Call grpcurl inside the VM instead of from the host
#                (useful when no port-forward tunnel is running)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROTO_FILE="${PROJECT_DIR}/proto/worker.proto"
PROTO_DIR="${PROJECT_DIR}/proto"

VM_NAME="zfs-dev"
VM_MOUNT_PATH="/home/ubuntu/worker"

GRPC_HOST="localhost"
GRPC_PORT="50051"
POOL_NAME="testpool"
VIA_VM=0

# Test counters
PASS=0
FAIL=0
SKIP=0

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${CYAN}[vm-test]${NC} $*"; }
ok()   { echo -e "${GREEN}[vm-test] ✓${NC} $*"; }
fail() { echo -e "${RED}[vm-test] ✗${NC} $*"; }
warn() { echo -e "${YELLOW}[vm-test] ~${NC} $*"; }
die()  { echo -e "${RED}[vm-test] ERROR:${NC} $*" >&2; exit 1; }

section() {
    echo ""
    echo -e "${BOLD}${CYAN}── $* ──────────────────────────────────────${NC}"
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            [[ -n "${2:-}" ]] || die "--host requires an argument."
            GRPC_HOST="$2"; shift 2 ;;
        --port)
            [[ -n "${2:-}" ]] || die "--port requires an argument."
            GRPC_PORT="$2"; shift 2 ;;
        --pool)
            [[ -n "${2:-}" ]] || die "--pool requires an argument."
            POOL_NAME="$2"; shift 2 ;;
        --via-vm) VIA_VM=1; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# grpcurl wrapper — runs either locally or inside the VM
# ---------------------------------------------------------------------------
run_grpcurl() {
    # run_grpcurl <service.Method> [json-body]
    local method="$1"
    local body="${2:-{\}}"

    if [[ $VIA_VM -eq 1 ]]; then
        multipass exec "$VM_NAME" -- bash -c "
            grpcurl -plaintext \
                -proto '${VM_MOUNT_PATH}/proto/worker.proto' \
                -d '${body}' \
                '[::1]:${GRPC_PORT}' \
                '${method}' 2>&1
        "
    else
        grpcurl -plaintext \
            -proto "$PROTO_FILE" \
            -import-path "$PROTO_DIR" \
            -d "$body" \
            "${GRPC_HOST}:${GRPC_PORT}" \
            "${method}" 2>&1
    fi
}

# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------
# run_test <description> <method> <body> [expected_substring]
run_test() {
    local desc="$1"
    local method="$2"
    local body="$3"
    local expect="${4:-}"

    local output
    local exit_code=0

    output=$(run_grpcurl "$method" "$body") || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        fail "${desc}"
        echo -e "       ${RED}grpcurl exited with code ${exit_code}${NC}"
        echo    "       Output: ${output}"
        (( FAIL++ )) || true
        return
    fi

    if [[ -n "$expect" ]] && ! echo "$output" | grep -q "$expect"; then
        fail "${desc}"
        echo -e "       ${RED}Expected to find '${expect}' in response${NC}"
        echo    "       Output: ${output}"
        (( FAIL++ )) || true
        return
    fi

    ok "${desc}"
    if [[ -n "$output" ]] && [[ "$output" != "{}" ]]; then
        echo "$output" | sed 's/^/       /'
    fi
    (( PASS++ )) || true
}

# run_test_expect_error <description> <method> <body> <expected_grpc_status>
run_test_expect_error() {
    local desc="$1"
    local method="$2"
    local body="$3"
    local expect_status="$4"

    local output
    output=$(run_grpcurl "$method" "$body") || true

    if echo "$output" | grep -qi "$expect_status"; then
        ok "${desc} (got expected error: ${expect_status})"
        (( PASS++ )) || true
    else
        fail "${desc} — expected error '${expect_status}', got:"
        echo    "       Output: ${output}"
        (( FAIL++ )) || true
    fi
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
log "Pre-flight checks ..."

if [[ $VIA_VM -eq 1 ]]; then
    command -v multipass &>/dev/null || die "multipass is not installed."
    VM_STATE=$(multipass list --format csv 2>/dev/null | grep "^${VM_NAME}," | cut -d',' -f2 || true)
    [[ "$VM_STATE" == "Running" ]] || die "VM '${VM_NAME}' is not running."

    # Install grpcurl in VM if missing
    multipass exec "$VM_NAME" -- bash -c "
        if ! command -v grpcurl &>/dev/null; then
            echo 'Installing grpcurl in VM ...'
            GRPCURL_VERSION=1.9.1
            curl -sSL \"https://github.com/fullstorydev/grpcurl/releases/download/v\${GRPCURL_VERSION}/grpcurl_\${GRPCURL_VERSION}_linux_arm64.tar.gz\" \
                | sudo tar -xz -C /usr/local/bin grpcurl
            echo 'grpcurl installed.'
        fi
    "
else
    command -v grpcurl &>/dev/null || die "grpcurl is not installed. Run: brew install grpcurl"
    [[ -f "$PROTO_FILE" ]] || die "Proto file not found: ${PROTO_FILE}"

    # Check that the service is reachable
    if ! grpcurl -plaintext \
            -proto "$PROTO_FILE" \
            -import-path "$PROTO_DIR" \
            "${GRPC_HOST}:${GRPC_PORT}" list &>/dev/null; then
        die "Cannot reach gRPC service at ${GRPC_HOST}:${GRPC_PORT}. Is the worker running and the tunnel active?"
    fi
fi

ok "Pre-flight checks passed."

# Dataset and snapshot names used across tests (timestamped to avoid collisions)
TS=$(date +%s)
DATASET="${POOL_NAME}/test-ds-${TS}"
SNAPSHOT_SUFFIX="snap-${TS}"
SNAPSHOT_FULL="${DATASET}@${SNAPSHOT_SUFFIX}"

# ===========================================================================
section "Pool operations"
# ===========================================================================

run_test \
    "ListPools — returns at least one pool" \
    "worker.Worker/ListPools" \
    '{}' \
    "pools"

# ===========================================================================
section "Dataset operations"
# ===========================================================================

run_test \
    "ListDatasets — lists datasets in ${POOL_NAME}" \
    "worker.Worker/ListDatasets" \
    "{\"pool\": \"${POOL_NAME}\"}" \
    "datasets"

run_test \
    "CreateDataset — create filesystem ${DATASET}" \
    "worker.Worker/CreateDataset" \
    "{\"name\": \"${DATASET}\", \"kind\": \"filesystem\"}" \
    "\"name\""

run_test \
    "GetDataset — retrieve ${DATASET}" \
    "worker.Worker/GetDataset" \
    "{\"name\": \"${DATASET}\"}" \
    "filesystem"

run_test \
    "ListDatasets — ${DATASET} now appears in list" \
    "worker.Worker/ListDatasets" \
    "{\"pool\": \"${POOL_NAME}\"}" \
    "${DATASET}"

run_test_expect_error \
    "CreateDataset — duplicate name returns error" \
    "worker.Worker/CreateDataset" \
    "{\"name\": \"${DATASET}\", \"kind\": \"filesystem\"}" \
    "Internal"

run_test_expect_error \
    "GetDataset — non-existent dataset returns NOT_FOUND" \
    "worker.Worker/GetDataset" \
    "{\"name\": \"${POOL_NAME}/does-not-exist-${TS}\"}" \
    "NotFound"

# ===========================================================================
section "Snapshot operations"
# ===========================================================================

run_test \
    "CreateSnapshot — create ${SNAPSHOT_FULL}" \
    "worker.Worker/CreateSnapshot" \
    "{\"dataset\": \"${DATASET}\", \"snap\": \"${SNAPSHOT_SUFFIX}\"}" \
    "\"name\""

run_test \
    "ListSnapshots — snapshot appears in list" \
    "worker.Worker/ListSnapshots" \
    "{\"dataset\": \"${DATASET}\"}" \
    "${SNAPSHOT_SUFFIX}"

run_test_expect_error \
    "CreateSnapshot — duplicate snap name returns error" \
    "worker.Worker/CreateSnapshot" \
    "{\"dataset\": \"${DATASET}\", \"snap\": \"${SNAPSHOT_SUFFIX}\"}" \
    "Internal"

run_test_expect_error \
    "ListSnapshots — unknown dataset returns NOT_FOUND" \
    "worker.Worker/ListSnapshots" \
    "{\"dataset\": \"${POOL_NAME}/no-such-ds-${TS}\"}" \
    "NotFound"

# ===========================================================================
section "Rollback"
# ===========================================================================

run_test \
    "Rollback — rollback ${DATASET} to ${SNAPSHOT_FULL}" \
    "worker.Worker/Rollback" \
    "{\"snapshot\": \"${SNAPSHOT_FULL}\", \"force\": false}" \
    ""   # any non-error response is a pass

# ===========================================================================
section "Cleanup"
# ===========================================================================

run_test \
    "DestroySnapshot — destroy ${SNAPSHOT_FULL}" \
    "worker.Worker/DestroySnapshot" \
    "{\"name\": \"${SNAPSHOT_FULL}\"}" \
    ""

run_test \
    "DestroyDataset — destroy ${DATASET}" \
    "worker.Worker/DestroyDataset" \
    "{\"name\": \"${DATASET}\", \"recursive\": false}" \
    ""

run_test_expect_error \
    "GetDataset — destroyed dataset returns NOT_FOUND" \
    "worker.Worker/GetDataset" \
    "{\"name\": \"${DATASET}\"}" \
    "NotFound"

# ===========================================================================
section "Recursive destroy"
# ===========================================================================

PARENT_DS="${POOL_NAME}/parent-${TS}"
CHILD_DS="${PARENT_DS}/child"

run_test \
    "CreateDataset — create parent ${PARENT_DS}" \
    "worker.Worker/CreateDataset" \
    "{\"name\": \"${PARENT_DS}\", \"kind\": \"filesystem\"}" \
    "\"name\""

run_test \
    "CreateDataset — create child ${CHILD_DS}" \
    "worker.Worker/CreateDataset" \
    "{\"name\": \"${CHILD_DS}\", \"kind\": \"filesystem\"}" \
    "\"name\""

run_test \
    "DestroyDataset — recursive destroy ${PARENT_DS}" \
    "worker.Worker/DestroyDataset" \
    "{\"name\": \"${PARENT_DS}\", \"recursive\": true}" \
    ""

run_test_expect_error \
    "GetDataset — child also gone after recursive destroy" \
    "worker.Worker/GetDataset" \
    "{\"name\": \"${CHILD_DS}\"}" \
    "NotFound"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo -e "${BOLD}── Results ─────────────────────────────────────────${NC}"
echo -e "  ${GREEN}Passed : ${PASS}${NC}"
echo -e "  ${RED}Failed : ${FAIL}${NC}"
if [[ $SKIP -gt 0 ]]; then
    echo -e "  ${YELLOW}Skipped: ${SKIP}${NC}"
fi
echo ""

if [[ $FAIL -gt 0 ]]; then
    exit 1
else
    echo -e "${GREEN}All tests passed.${NC}"
    exit 0
fi
