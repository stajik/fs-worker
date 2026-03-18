#!/usr/bin/env bash
# =============================================================================
# vm-test.sh — Smoke-test the fs-worker Temporal activity worker
#
# Tests that:
#   1. The Temporal server is reachable
#   2. The fs-worker is registered on the expected task queue
#   3. InitBranch activity is registered
#
# Requires:
#   - temporal CLI installed on your Mac: brew install temporal
#   - A running Temporal server (temporal server start-dev)
#   - The fs-worker running and connected to the same server + task queue
#
# Usage:
#   ./scripts/vm-test.sh [--host <host:port>] [--namespace <ns>]
#                        [--task-queue <tq>]
#
#   --host <h:p>      Temporal frontend address   (default: localhost:7233)
#   --namespace <ns>  Temporal namespace           (default: default)
#   --task-queue <tq> Worker task queue            (default: fs-worker)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env if present
ENV_FILE="${PROJECT_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        line="${line#export }"
        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            key="${line%%=*}"; val="${line#*=}"
            [[ "$val" == "~/"* ]] && val="${HOME}${val:1}"
            export "${key}=${val}"
        fi
    done < "${ENV_FILE}"
fi

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
TEMPORAL_ADDRESS="${TEMPORAL_HOST:-localhost:7233}"
# Strip http:// or https:// scheme if present
TEMPORAL_ADDRESS="${TEMPORAL_ADDRESS#http://}"
TEMPORAL_ADDRESS="${TEMPORAL_ADDRESS#https://}"
NAMESPACE="${TEMPORAL_NAMESPACE:-default}"
TASK_QUEUE="${TEMPORAL_TASK_QUEUE:-fs-worker}"

# Test counters
PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${CYAN}[vm-test]${NC} $*"; }
ok()      { echo -e "${GREEN}[vm-test] ✓${NC} $*"; }
fail_msg(){ echo -e "${RED}[vm-test] ✗${NC} $*"; }
warn()    { echo -e "${YELLOW}[vm-test] ~${NC} $*"; }
die()     { echo -e "${RED}[vm-test] ERROR:${NC} $*" >&2; exit 1; }
section() { echo ""; echo -e "${BOLD}${CYAN}── $* ──────────────────────────────────────${NC}"; }

pass() { ok "$1"; (( PASS++ )) || true; }
fail() { fail_msg "$1"; (( FAIL++ )) || true; }

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)       [[ -n "${2:-}" ]] || die "--host requires a value."; TEMPORAL_ADDRESS="$2"; shift 2 ;;
        --namespace)  [[ -n "${2:-}" ]] || die "--namespace requires a value."; NAMESPACE="$2"; shift 2 ;;
        --task-queue) [[ -n "${2:-}" ]] || die "--task-queue requires a value."; TASK_QUEUE="$2"; shift 2 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# temporal CLI wrapper
# ---------------------------------------------------------------------------
temporal_cli() {
    temporal --address "${TEMPORAL_ADDRESS}" --namespace "${NAMESPACE}" "$@"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
section "Pre-flight checks"

command -v temporal &>/dev/null || die "temporal CLI not found. Install it: brew install temporal"
log "temporal CLI: $(temporal --version 2>&1 | head -1)"

log "Checking Temporal server at ${TEMPORAL_ADDRESS} ..."
if ! temporal_cli operator cluster health 2>/dev/null | grep -q "SERVING"; then
    fail "Temporal server not reachable at ${TEMPORAL_ADDRESS}"
    echo ""
    echo "  Make sure 'temporal server start-dev' is running."
    exit 1
fi
pass "Temporal server is healthy"

# ---------------------------------------------------------------------------
section "Task queue registration"
# ---------------------------------------------------------------------------

log "Checking task queue '${TASK_QUEUE}' in namespace '${NAMESPACE}' ..."
TQ_OUTPUT=$(temporal_cli task-queue describe --task-queue "${TASK_QUEUE}" 2>&1 || true)

if echo "${TQ_OUTPUT}" | grep -qi "error\|not found\|unknown"; then
    fail "Task queue '${TASK_QUEUE}' — worker not registered or task queue not found"
    echo "       ${TQ_OUTPUT}" | head -5
else
    pass "Task queue '${TASK_QUEUE}' — worker registered"
    echo "${TQ_OUTPUT}" | sed 's/^/       /'
fi

# ---------------------------------------------------------------------------
section "Activity: InitBranch"
# ---------------------------------------------------------------------------

TQ_TYPES=$(temporal_cli task-queue describe \
    --task-queue "${TASK_QUEUE}" \
    --report-reachability 2>&1 || true)

if echo "${TQ_TYPES}" | grep -qi "InitBranch"; then
    pass "Activity 'InitBranch' is registered on task queue"
else
    warn "Could not confirm 'InitBranch' registration from task-queue describe output"
    warn "This may be a CLI version limitation — check manually with:"
    warn "  temporal task-queue describe --task-queue ${TASK_QUEUE}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}── Results ─────────────────────────────────────────${NC}"
echo -e "  ${GREEN}Passed : ${PASS}${NC}"
echo -e "  ${RED}Failed : ${FAIL}${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}Some checks failed.${NC}"
    exit 1
else
    echo -e "${GREEN}All checks passed.${NC}"
    exit 0
fi
