#!/usr/bin/env bash
# =============================================================================
# vm-provision.sh — Provision an a1.metal EC2 instance + EBS volume + S3 bucket on AWS
#
# Assumes:
#   - AWS CLI v2 is installed and you are already authenticated
#     (via `aws sso login`, environment variables, or an instance profile)
#   - If AWS_KEY_NAME / AWS_PEM_PATH are not set, a new key pair is created
#     automatically and the PEM is saved to ~/.ssh/fs-worker.pem
#
# What it does:
#   1. Resolves or creates a VPC, subnet, internet gateway, and route table
#   2. Creates a dedicated security group (SSH on port 22 from your public IP)
#   3. Launches an a1.metal instance with Ubuntu 24.04 arm64
#   4. Creates and attaches an EBS gp3 volume for the ZFS pool
#   5. Waits for the instance to pass status checks and be SSH-reachable
#   6. Creates an S3 bucket for ZFS snapshot diffs and grants the instance
#      read/write access via an IAM instance profile
#   7. Writes / updates .env with REMOTE_HOST, REMOTE_USER, REMOTE_PEM,
#      REMOTE_POOL_DEVICE, AWS_S3_BUCKET, and AWS_INSTANCE_ID so the other
#      scripts work immediately after this one finishes
#
# Usage:
#   ./scripts/vm-provision.sh [--destroy]
#
#   (no flags)   Provision a new instance (idempotent — skips steps already done)
#   --destroy    Terminate the instance and delete associated AWS resources
#
# Configuration (set in .env or as environment variables before running):
#   AWS_REGION          AWS region                          (default: us-east-1)
#   AWS_PROFILE         AWS CLI named profile               (optional — uses default if unset)
#   AWS_KEY_NAME        Name of the EC2 key pair            (default: fs-worker — created if absent)
#   AWS_PEM_PATH        Local path to the matching .pem     (default: ~/.ssh/fs-worker.pem — created if absent)
#   AWS_INSTANCE_TYPE   EC2 instance type                   (default: a1.metal)
#   AWS_EBS_SIZE_GB     Size of the ZFS data volume in GB   (default: 20)
#   AWS_EBS_TYPE        EBS volume type                     (default: gp3)
#   AWS_VPC_ID          Existing VPC to use (optional — created if absent)
#   AWS_SUBNET_ID       Existing subnet to use (optional — created if absent)
#   AWS_SG_ID           Existing security group (optional — created if absent)
#   AWS_EIP_ID          Existing Elastic IP allocation ID   (optional — allocated if absent)
#   AWS_S3_BUCKET       Name of the S3 bucket for diffs     (default: fs-worker-diffs-<account-id>-<region>)
#   AWS_IAM_ROLE_NAME   IAM role name for S3 access         (default: fs-worker-s3-role)
#   AWS_INSTANCE_PROFILE IAM instance profile name          (default: fs-worker-s3-profile)
#   REMOTE_USER         SSH login user on the instance      (default: ubuntu)
#   REMOTE_WORK_DIR     Project dir on the instance         (default: /home/worker/fs-worker)
#   ZFS_POOL            ZFS pool name                       (default: testpool)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"
LOG_PREFIX="[vm-provision]"

# ---------------------------------------------------------------------------
# Colours (duplicated from lib.sh so this script is standalone — it runs
# before .env has REMOTE_HOST and therefore before remote mode is valid)
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${CYAN}${LOG_PREFIX}${NC} $*"; }
ok()   { echo -e "${GREEN}${LOG_PREFIX}${NC} $*"; }
warn() { echo -e "${YELLOW}${LOG_PREFIX}${NC} $*"; }
die()  { echo -e "${RED}${LOG_PREFIX} ERROR:${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# .env loader (same tilde-expanding logic as lib.sh)
# ---------------------------------------------------------------------------
load_env() {
    [[ -f "${ENV_FILE}" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        line="${line#export }"
        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            local key="${line%%=*}"
            local val="${line#*=}"
            [[ "$val" == "~/"* ]] && val="${HOME}${val:1}"
            export "${key}=${val}"
        fi
    done < "${ENV_FILE}"
}

load_env

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_INSTANCE_TYPE="${AWS_INSTANCE_TYPE:-a1.metal}"
AWS_EBS_SIZE_GB="${AWS_EBS_SIZE_GB:-20}"
AWS_EBS_TYPE="${AWS_EBS_TYPE:-gp3}"
AWS_VPC_CIDR="10.0.0.0/16"
AWS_SUBNET_CIDR="10.0.1.0/24"
AWS_KEY_NAME="${AWS_KEY_NAME:-}"
AWS_PEM_PATH="${AWS_PEM_PATH:-}"
AWS_VPC_ID="${AWS_VPC_ID:-}"
AWS_SUBNET_ID="${AWS_SUBNET_ID:-}"
AWS_SG_ID="${AWS_SG_ID:-}"
AWS_EIP_ID="${AWS_EIP_ID:-}"
AWS_S3_BUCKET="${AWS_S3_BUCKET:-}"
AWS_IAM_ROLE_NAME="${AWS_IAM_ROLE_NAME:-fs-worker-s3-role}"
AWS_INSTANCE_PROFILE="${AWS_INSTANCE_PROFILE:-fs-worker-s3-profile}"
AWS_INSTANCE_ID="${AWS_INSTANCE_ID:-}"
REMOTE_USER="${REMOTE_USER:-ubuntu}"
REMOTE_WORK_DIR="${REMOTE_WORK_DIR:-/home/worker/fs-worker}"
ZFS_POOL="${ZFS_POOL:-testpool}"

# ---------------------------------------------------------------------------
# aws() wrapper — injects --profile and --region into every AWS CLI call
# so neither has to be repeated at every call site.
# ---------------------------------------------------------------------------
aws() {
    local args=()
    [[ -n "${AWS_PROFILE}" ]] && args+=(--profile "${AWS_PROFILE}")
    args+=(--region "${AWS_REGION}")
    command aws "${args[@]}" "$@"
}

# Tag applied to every resource so they can be found again on re-runs
TAG_KEY="fs-worker-provision"
TAG_VALUE="true"
NAME_TAG="fs-worker"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
DESTROY=0
for arg in "$@"; do
    case "$arg" in
        --destroy) DESTROY=1 ;;
        *) die "Unknown argument: $arg. Usage: $0 [--destroy]" ;;
    esac
done

# ---------------------------------------------------------------------------
# Helper: write or update a single KEY=value line in .env
# ---------------------------------------------------------------------------
env_set() {
    local key="$1"
    local val="$2"

    # Create .env if it doesn't exist yet
    [[ -f "${ENV_FILE}" ]] || touch "${ENV_FILE}"

    if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
        # Replace the existing line (macOS-compatible sed)
        sed -i '' "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
    else
        echo "${key}=${val}" >> "${ENV_FILE}"
    fi
}

# ---------------------------------------------------------------------------
# Helper: get the value of a tag from a describe-* output
# ---------------------------------------------------------------------------
aws_tag() {
    # aws_tag <json-tags-array> <key>
    echo "$1" | jq -r --arg k "$2" '.[] | select(.Key==$k) | .Value // empty'
}

# ---------------------------------------------------------------------------
# Helper: wait with a spinner
# ---------------------------------------------------------------------------
wait_for() {
    local description="$1"; shift
    local max_attempts="$1"; shift
    local sleep_secs="$1"; shift
    # remaining args are the command to poll

    local attempt=0
    log "Waiting for: ${description} ..."
    while ! "$@" &>/dev/null; do
        attempt=$(( attempt + 1 ))
        if [[ $attempt -ge $max_attempts ]]; then
            die "Timed out waiting for: ${description}"
        fi
        printf "  attempt %d/%d — sleeping %ds ...\r" "$attempt" "$max_attempts" "$sleep_secs"
        sleep "$sleep_secs"
    done
    echo ""
    ok "${description} — done."
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
command -v aws  &>/dev/null || die "AWS CLI not found. Install it: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
command -v jq   &>/dev/null || die "jq not found. Install it: brew install jq"
command -v ssh  &>/dev/null || die "ssh not found."

# Verify AWS credentials are working
aws sts get-caller-identity &>/dev/null \
    || die "AWS credentials are not configured or have expired.\
${AWS_PROFILE:+ (profile: ${AWS_PROFILE})} Run 'aws sso login' or set AWS_* env vars."

if [[ $DESTROY -eq 0 ]]; then
    # Expand tilde manually in case it came from the environment rather than load_env
    [[ "${AWS_PEM_PATH}" == "~/"* ]] && AWS_PEM_PATH="${HOME}${AWS_PEM_PATH:1}"

    # ---------------------------------------------------------------------------
    # Key pair — auto-create if AWS_KEY_NAME or AWS_PEM_PATH are not configured
    # ---------------------------------------------------------------------------
    _DEFAULT_KEY_NAME="fs-worker"
    _DEFAULT_PEM_PATH="${HOME}/.ssh/fs-worker.pem"

    if [[ -z "${AWS_KEY_NAME}" && -z "${AWS_PEM_PATH}" ]]; then
        # Neither set — check whether we already created one on a previous run
        EXISTING_KEY=$(aws ec2 describe-key-pairs \
            --filters "Name=key-name,Values=${_DEFAULT_KEY_NAME}" \
            --query 'KeyPairs[0].KeyName' \
            --output text 2>/dev/null || true)
        [[ "$EXISTING_KEY" == "None" ]] && EXISTING_KEY=""

        if [[ -n "$EXISTING_KEY" && -f "${_DEFAULT_PEM_PATH}" ]]; then
            # Already exists from a prior run — reuse silently
            warn "AWS_KEY_NAME not set — reusing existing key pair '${_DEFAULT_KEY_NAME}'."
            AWS_KEY_NAME="${_DEFAULT_KEY_NAME}"
            AWS_PEM_PATH="${_DEFAULT_PEM_PATH}"
        else
            # Create a brand-new key pair in AWS and save the PEM locally
            if [[ -n "$EXISTING_KEY" ]]; then
                # Key exists in AWS but PEM is gone — can't recover, make a new one
                warn "Key pair '${_DEFAULT_KEY_NAME}' exists in AWS but PEM not found locally."
                warn "Deleting the old key pair and creating a fresh one ..."
                aws ec2 delete-key-pair --key-name "${_DEFAULT_KEY_NAME}" &>/dev/null
            fi

            log "No key pair configured — creating '${_DEFAULT_KEY_NAME}' ..."
            mkdir -p "${HOME}/.ssh"
            aws ec2 create-key-pair \
                --key-name "${_DEFAULT_KEY_NAME}" \
                --key-type rsa \
                --key-format pem \
                --query 'KeyMaterial' \
                --output text > "${_DEFAULT_PEM_PATH}"
            chmod 600 "${_DEFAULT_PEM_PATH}"

            AWS_KEY_NAME="${_DEFAULT_KEY_NAME}"
            AWS_PEM_PATH="${_DEFAULT_PEM_PATH}"

            env_set "AWS_KEY_NAME" "${AWS_KEY_NAME}"
            env_set "AWS_PEM_PATH" "${AWS_PEM_PATH}"
            ok "Created key pair '${AWS_KEY_NAME}' — PEM saved to ${AWS_PEM_PATH}"
        fi

    elif [[ -z "${AWS_KEY_NAME}" ]]; then
        die "AWS_PEM_PATH is set to '${AWS_PEM_PATH}' but AWS_KEY_NAME is not set. Set it in ${ENV_FILE}."

    elif [[ -z "${AWS_PEM_PATH}" ]]; then
        die "AWS_KEY_NAME is set to '${AWS_KEY_NAME}' but AWS_PEM_PATH is not set. Set it in ${ENV_FILE}."

    else
        # Both are explicitly configured — validate them
        [[ -f "${AWS_PEM_PATH}" ]] || die "PEM file not found: ${AWS_PEM_PATH}"

        aws ec2 describe-key-pairs \
            --key-names "${AWS_KEY_NAME}" \
            --query 'KeyPairs[0].KeyName' \
            --output text &>/dev/null \
            || die "Key pair '${AWS_KEY_NAME}' not found in region ${AWS_REGION}."
    fi
fi



# =============================================================================
# DESTROY MODE
# =============================================================================
if [[ $DESTROY -eq 1 ]]; then
    log "Destroy mode — tearing down all fs-worker AWS resources in ${AWS_REGION} ..."
    echo ""

    # ---- Terminate instance ----
    if [[ -n "${AWS_INSTANCE_ID}" ]]; then
        INST_STATE=$(aws ec2 describe-instances \
            --instance-ids "${AWS_INSTANCE_ID}" \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text 2>/dev/null || echo "not-found")

        if [[ "$INST_STATE" != "terminated" && "$INST_STATE" != "not-found" ]]; then
            log "Terminating instance ${AWS_INSTANCE_ID} (state: ${INST_STATE}) ..."
            aws ec2 terminate-instances \
                --instance-ids "${AWS_INSTANCE_ID}" &>/dev/null
            aws ec2 wait instance-terminated \
                --instance-ids "${AWS_INSTANCE_ID}"
            ok "Instance terminated."
        else
            warn "Instance ${AWS_INSTANCE_ID} is already ${INST_STATE} — skipping."
        fi
    else
        # Try to find by tag
        FOUND_ID=$(aws ec2 describe-instances \
            --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
                      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
            --query 'Reservations[0].Instances[0].InstanceId' \
            --output text 2>/dev/null || true)

        if [[ -n "$FOUND_ID" && "$FOUND_ID" != "None" ]]; then
            log "Found instance ${FOUND_ID} by tag — terminating ..."
            aws ec2 terminate-instances \
                --instance-ids "${FOUND_ID}" &>/dev/null
            aws ec2 wait instance-terminated \
                --instance-ids "${FOUND_ID}"
            ok "Instance terminated."
        else
            warn "No running instance found — skipping termination."
        fi
    fi

    # ---- Delete detached EBS volumes tagged for this project ----
    VOLS=$(aws ec2 describe-volumes \
        --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
                  "Name=status,Values=available" \
        --query 'Volumes[*].VolumeId' \
        --output text 2>/dev/null || true)

    for vol in $VOLS; do
        log "Deleting EBS volume ${vol} ..."
        aws ec2 delete-volume --volume-id "${vol}" &>/dev/null
        ok "Deleted ${vol}."
    done

    # ---- Empty and delete S3 bucket ----
    DESTROY_S3_BUCKET=$(grep '^AWS_S3_BUCKET=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2 || true)
    if [[ -n "${DESTROY_S3_BUCKET}" ]]; then
        log "Emptying and deleting S3 bucket ${DESTROY_S3_BUCKET} ..."
        aws s3 rm "s3://${DESTROY_S3_BUCKET}" --recursive 2>/dev/null \
            && ok "Bucket emptied." \
            || warn "Could not empty bucket ${DESTROY_S3_BUCKET} (may already be empty or gone)."
        aws s3api delete-bucket --bucket "${DESTROY_S3_BUCKET}" 2>/dev/null \
            && ok "Bucket deleted." \
            || warn "Could not delete bucket ${DESTROY_S3_BUCKET}."
    fi

    # ---- Delete IAM instance profile and role ----
    DESTROY_PROFILE="${AWS_INSTANCE_PROFILE}"
    DESTROY_ROLE="${AWS_IAM_ROLE_NAME}"
    if aws iam get-instance-profile --instance-profile-name "${DESTROY_PROFILE}" &>/dev/null; then
        log "Removing role from instance profile and deleting ..."
        aws iam remove-role-from-instance-profile \
            --instance-profile-name "${DESTROY_PROFILE}" \
            --role-name "${DESTROY_ROLE}" 2>/dev/null || true
        aws iam delete-instance-profile \
            --instance-profile-name "${DESTROY_PROFILE}" 2>/dev/null \
            && ok "Instance profile '${DESTROY_PROFILE}' deleted." \
            || warn "Could not delete instance profile '${DESTROY_PROFILE}'."
    fi
    if aws iam get-role --role-name "${DESTROY_ROLE}" &>/dev/null; then
        log "Deleting IAM role '${DESTROY_ROLE}' ..."
        # Delete inline policies first
        POLICIES=$(aws iam list-role-policies --role-name "${DESTROY_ROLE}" \
            --query 'PolicyNames' --output text 2>/dev/null || true)
        for pol in $POLICIES; do
            aws iam delete-role-policy --role-name "${DESTROY_ROLE}" --policy-name "$pol" 2>/dev/null || true
        done
        aws iam delete-role --role-name "${DESTROY_ROLE}" 2>/dev/null \
            && ok "IAM role '${DESTROY_ROLE}' deleted." \
            || warn "Could not delete IAM role '${DESTROY_ROLE}'."
    fi

    # ---- Delete security group ----
    if [[ -n "${AWS_SG_ID}" ]]; then
        log "Deleting security group ${AWS_SG_ID} ..."
        aws ec2 delete-security-group \
            --group-id "${AWS_SG_ID}" 2>/dev/null && ok "Deleted security group." \
            || warn "Could not delete security group ${AWS_SG_ID} (may still have dependencies)."
    fi

    # ---- Release the Elastic IP ----
    DESTROY_EIP_ID=$(grep '^AWS_EIP_ID=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2 || true)
    if [[ -n "${DESTROY_EIP_ID}" ]]; then
        log "Disassociating and releasing Elastic IP ${DESTROY_EIP_ID} ..."
        # Disassociate first (ignore error if already disassociated)
        ASSOC_ID=$(aws ec2 describe-addresses \
            --allocation-ids "${DESTROY_EIP_ID}" \
            --query 'Addresses[0].AssociationId' \
            --output text 2>/dev/null || true)
        if [[ -n "${ASSOC_ID}" && "${ASSOC_ID}" != "None" ]]; then
            aws ec2 disassociate-address --association-id "${ASSOC_ID}" 2>/dev/null || true
        fi
        aws ec2 release-address --allocation-id "${DESTROY_EIP_ID}" 2>/dev/null \
            && ok "Elastic IP released." \
            || warn "Could not release Elastic IP ${DESTROY_EIP_ID}."
    fi

    # ---- Delete the auto-created key pair if it matches the default name ----
    DESTROY_KEY_NAME=$(grep '^AWS_KEY_NAME=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2 || true)
    DESTROY_PEM_PATH=$(grep '^AWS_PEM_PATH=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2 || true)
    [[ "${DESTROY_PEM_PATH}" == "~/"* ]] && DESTROY_PEM_PATH="${HOME}${DESTROY_PEM_PATH:1}"

    if [[ "${DESTROY_KEY_NAME}" == "fs-worker" ]]; then
        log "Deleting auto-created key pair '${DESTROY_KEY_NAME}' ..."
        aws ec2 delete-key-pair --key-name "${DESTROY_KEY_NAME}" 2>/dev/null && ok "Key pair deleted." \
            || warn "Could not delete key pair '${DESTROY_KEY_NAME}'."
        if [[ -f "${DESTROY_PEM_PATH}" ]]; then
            rm -f "${DESTROY_PEM_PATH}"
            ok "Removed local PEM: ${DESTROY_PEM_PATH}"
        fi
    fi

    # ---- Clean .env ----
    log "Removing AWS/remote entries from ${ENV_FILE} ..."
    for key in AWS_INSTANCE_ID AWS_EIP_ID AWS_VPC_ID AWS_SUBNET_ID AWS_SG_ID \
                AWS_KEY_NAME AWS_PEM_PATH AWS_S3_BUCKET REMOTE_HOST REMOTE_POOL_DEVICE; do
        sed -i '' "/^${key}=/d" "${ENV_FILE}" 2>/dev/null || true
    done

    echo ""
    ok "============================================================"
    ok "  All fs-worker AWS resources have been destroyed."
    ok "  REMOTE_HOST and related entries removed from .env."
    ok "============================================================"
    exit 0
fi

# =============================================================================
# PROVISION MODE
# =============================================================================

echo ""
log "Provisioning ${AWS_INSTANCE_TYPE} + EBS in ${AWS_REGION} ..."
log "Profile   : ${AWS_PROFILE:-<default>}"
log "Key pair  : ${AWS_KEY_NAME} (${AWS_PEM_PATH})"
log "EBS       : ${AWS_EBS_SIZE_GB} GB ${AWS_EBS_TYPE}"
echo ""

# ---------------------------------------------------------------------------
# Step 1: VPC
# ---------------------------------------------------------------------------
log "Step 1/9 — VPC ..."

if [[ -z "${AWS_VPC_ID}" ]]; then
    # Try to find an existing tagged VPC first
    AWS_VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
        --query 'Vpcs[0].VpcId' \
        --output text 2>/dev/null || true)
    [[ "$AWS_VPC_ID" == "None" ]] && AWS_VPC_ID=""
fi

if [[ -z "${AWS_VPC_ID}" ]]; then
    log "  Creating VPC (${AWS_VPC_CIDR}) ..."
    AWS_VPC_ID=$(aws ec2 create-vpc \
        --cidr-block "${AWS_VPC_CIDR}" \
        --query 'Vpc.VpcId' \
        --output text)

    aws ec2 create-tags \
        --resources "${AWS_VPC_ID}" \
        --tags "Key=Name,Value=${NAME_TAG}" "Key=${TAG_KEY},Value=${TAG_VALUE}"

    # Enable DNS hostnames (needed for public IP reverse DNS)
    aws ec2 modify-vpc-attribute \
        --vpc-id "${AWS_VPC_ID}" \
        --enable-dns-hostnames '{"Value":true}'

    ok "  Created VPC: ${AWS_VPC_ID}"
    env_set "AWS_VPC_ID" "${AWS_VPC_ID}"
else
    ok "  Reusing existing VPC: ${AWS_VPC_ID}"
fi

# ---------------------------------------------------------------------------
# Step 2: Internet Gateway
# ---------------------------------------------------------------------------
log "Step 2/9 — Internet Gateway ..."

IGW_ID=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=${AWS_VPC_ID}" \
    --query 'InternetGateways[0].InternetGatewayId' \
    --output text 2>/dev/null || true)
[[ "$IGW_ID" == "None" ]] && IGW_ID=""

if [[ -z "${IGW_ID}" ]]; then
    log "  Creating Internet Gateway ..."
    IGW_ID=$(aws ec2 create-internet-gateway \
        --query 'InternetGateway.InternetGatewayId' \
        --output text)

    aws ec2 create-tags \
        --resources "${IGW_ID}" \
        --tags "Key=Name,Value=${NAME_TAG}" "Key=${TAG_KEY},Value=${TAG_VALUE}"

    aws ec2 attach-internet-gateway \
        --internet-gateway-id "${IGW_ID}" \
        --vpc-id "${AWS_VPC_ID}"

    ok "  Created and attached IGW: ${IGW_ID}"
else
    ok "  Reusing existing IGW: ${IGW_ID}"
fi

# ---------------------------------------------------------------------------
# Step 3: Subnet
# ---------------------------------------------------------------------------
log "Step 3/9 — Subnet ..."

if [[ -z "${AWS_SUBNET_ID}" ]]; then
    AWS_SUBNET_ID=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${AWS_VPC_ID}" \
                  "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
        --query 'Subnets[0].SubnetId' \
        --output text 2>/dev/null || true)
    [[ "$AWS_SUBNET_ID" == "None" ]] && AWS_SUBNET_ID=""
fi

if [[ -z "${AWS_SUBNET_ID}" ]]; then
    # Pick the first available AZ that supports a1.metal
    AZ=$(aws ec2 describe-instance-type-offerings \
        --location-type availability-zone \
        --filters "Name=instance-type,Values=${AWS_INSTANCE_TYPE}" \
        --query 'InstanceTypeOfferings[0].Location' \
        --output text 2>/dev/null || true)

    [[ -z "${AZ}" || "${AZ}" == "None" ]] && \
        die "${AWS_INSTANCE_TYPE} is not available in ${AWS_REGION}. Try a different region."

    log "  Creating subnet in AZ ${AZ} ..."
    AWS_SUBNET_ID=$(aws ec2 create-subnet \
        --vpc-id "${AWS_VPC_ID}" \
        --cidr-block "${AWS_SUBNET_CIDR}" \
        --availability-zone "${AZ}" \
        --query 'Subnet.SubnetId' \
        --output text)

    aws ec2 create-tags \
        --resources "${AWS_SUBNET_ID}" \
        --tags "Key=Name,Value=${NAME_TAG}" "Key=${TAG_KEY},Value=${TAG_VALUE}"

    # Auto-assign public IPs to instances launched into this subnet
    aws ec2 modify-subnet-attribute \
        --subnet-id "${AWS_SUBNET_ID}" \
        --map-public-ip-on-launch

    ok "  Created subnet: ${AWS_SUBNET_ID} in ${AZ}"
    env_set "AWS_SUBNET_ID" "${AWS_SUBNET_ID}"
else
    ok "  Reusing existing subnet: ${AWS_SUBNET_ID}"
fi

# ---------------------------------------------------------------------------
# Step 4: Route Table (public — 0.0.0.0/0 → IGW)
# ---------------------------------------------------------------------------
log "Step 4/9 — Route table ..."

RT_ID=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=${AWS_VPC_ID}" \
              "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
    --query 'RouteTables[0].RouteTableId' \
    --output text 2>/dev/null || true)
[[ "$RT_ID" == "None" ]] && RT_ID=""

if [[ -z "${RT_ID}" ]]; then
    log "  Creating route table ..."
    RT_ID=$(aws ec2 create-route-table \
        --vpc-id "${AWS_VPC_ID}" \
        --query 'RouteTable.RouteTableId' \
        --output text)

    aws ec2 create-tags \
        --resources "${RT_ID}" \
        --tags "Key=Name,Value=${NAME_TAG}" "Key=${TAG_KEY},Value=${TAG_VALUE}"

    aws ec2 create-route \
        --route-table-id "${RT_ID}" \
        --destination-cidr-block 0.0.0.0/0 \
        --gateway-id "${IGW_ID}" &>/dev/null

    aws ec2 associate-route-table \
        --route-table-id "${RT_ID}" \
        --subnet-id "${AWS_SUBNET_ID}" &>/dev/null

    ok "  Created and associated route table: ${RT_ID}"
else
    ok "  Reusing existing route table: ${RT_ID}"
fi

# ---------------------------------------------------------------------------
# Step 5: Security Group (SSH from your current public IP only)
# ---------------------------------------------------------------------------
log "Step 5/9 — Security group ..."

MY_IP=$(curl -sf https://checkip.amazonaws.com || curl -sf https://api.ipify.org || true)
[[ -z "${MY_IP}" ]] && die "Could not determine your public IP address. Check your internet connection."
MY_CIDR="${MY_IP}/32"
log "  Your public IP: ${MY_IP}"

if [[ -z "${AWS_SG_ID}" ]]; then
    AWS_SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=${AWS_VPC_ID}" \
                  "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || true)
    [[ "$AWS_SG_ID" == "None" ]] && AWS_SG_ID=""
fi

if [[ -z "${AWS_SG_ID}" ]]; then
    log "  Creating security group ..."
    AWS_SG_ID=$(aws ec2 create-security-group \
        --group-name "${NAME_TAG}-sg" \
        --description "fs-worker SSH access" \
        --vpc-id "${AWS_VPC_ID}" \
        --query 'GroupId' \
        --output text)

    aws ec2 create-tags \
        --resources "${AWS_SG_ID}" \
        --tags "Key=Name,Value=${NAME_TAG}-sg" "Key=${TAG_KEY},Value=${TAG_VALUE}"

    ok "  Created security group: ${AWS_SG_ID}"
    env_set "AWS_SG_ID" "${AWS_SG_ID}"
else
    ok "  Reusing existing security group: ${AWS_SG_ID}"
fi

# Ensure SSH ingress rule exists for current IP (idempotent — ignore duplicate error)
RULE_EXISTS=$(aws ec2 describe-security-groups \
    --group-ids "${AWS_SG_ID}" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`] | [0].IpRanges[?CidrIp=='${MY_CIDR}'] | [0].CidrIp" \
    --output text 2>/dev/null || true)

if [[ -z "${RULE_EXISTS}" || "${RULE_EXISTS}" == "None" ]]; then
    log "  Adding SSH ingress rule for ${MY_CIDR} ..."
    aws ec2 authorize-security-group-ingress \
        --group-id "${AWS_SG_ID}" \
        --protocol tcp \
        --port 22 \
        --cidr "${MY_CIDR}" 2>/dev/null || true
    ok "  SSH (port 22) open to ${MY_CIDR}."
else
    ok "  SSH ingress rule for ${MY_CIDR} already present."
fi

# ---------------------------------------------------------------------------
# Step 6: Resolve the Ubuntu 24.04 arm64 AMI (latest official Canonical AMI)
# ---------------------------------------------------------------------------
log "Step 6/9 — Resolving Ubuntu 24.04 LTS arm64 AMI ..."

AMI_ID=$(aws ec2 describe-images \
    --owners 099720109477 \
    --filters \
        "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*" \
        "Name=architecture,Values=arm64" \
        "Name=state,Values=available" \
        "Name=root-device-type,Values=ebs" \
        "Name=virtualization-type,Values=hvm" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)

[[ -z "${AMI_ID}" || "${AMI_ID}" == "None" ]] && \
    die "Could not find a Ubuntu 24.04 arm64 AMI in ${AWS_REGION}."

ok "  AMI: ${AMI_ID}"

# ---------------------------------------------------------------------------
# Step 7: Launch the EC2 instance (idempotent — reuse if already running)
# ---------------------------------------------------------------------------
log "Step 7/9 — EC2 instance ..."

if [[ -n "${AWS_INSTANCE_ID}" ]]; then
    INST_STATE=$(aws ec2 describe-instances \
        --instance-ids "${AWS_INSTANCE_ID}" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null || echo "not-found")

    if [[ "$INST_STATE" == "terminated" || "$INST_STATE" == "not-found" ]]; then
        warn "  Previously recorded instance ${AWS_INSTANCE_ID} is ${INST_STATE} — launching a new one."
        AWS_INSTANCE_ID=""
    else
        ok "  Reusing existing instance: ${AWS_INSTANCE_ID} (${INST_STATE})"
    fi
fi

if [[ -z "${AWS_INSTANCE_ID}" ]]; then
    # Also check by tag in case .env was wiped
    FOUND_ID=$(aws ec2 describe-instances \
        --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null || true)
    [[ -n "${FOUND_ID}" && "${FOUND_ID}" != "None" ]] && AWS_INSTANCE_ID="${FOUND_ID}"
fi

if [[ -z "${AWS_INSTANCE_ID}" ]]; then
    log "  Launching ${AWS_INSTANCE_TYPE} instance ..."

    # User-data script runs at first boot as root, before any SSH connection
    # is attempted by our scripts.  It switches sshd from socket-activated
    # (Ubuntu 24.04 default) to a persistent daemon so that concurrent SSH
    # sessions during heavy apt/cargo work don't hit the socket backlog limit
    # and silently drop connections.
    USER_DATA=$(base64 <<'USERDATA'
#!/bin/bash
# Disable ssh.socket (per-connection spawn) and enable ssh.service (persistent
# daemon) so sshd is always listening without spawning a new process per call.
systemctl disable --now ssh.socket  2>/dev/null || true
systemctl enable  --now ssh.service 2>/dev/null || true
USERDATA
)

    # a1.metal requires dedicated tenancy on bare-metal; use default for
    # compatibility — bare metal instances always run on dedicated hardware.
    AWS_INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "${AMI_ID}" \
        --instance-type "${AWS_INSTANCE_TYPE}" \
        --key-name "${AWS_KEY_NAME}" \
        --subnet-id "${AWS_SUBNET_ID}" \
        --security-group-ids "${AWS_SG_ID}" \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
        --metadata-options 'HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled' \
        --user-data "${USER_DATA}" \
        --tag-specifications \
            "ResourceType=instance,Tags=[{Key=Name,Value=${NAME_TAG}},{Key=${TAG_KEY},Value=${TAG_VALUE}}]" \
        --query 'Instances[0].InstanceId' \
        --output text)

    ok "  Launched instance: ${AWS_INSTANCE_ID}"
    env_set "AWS_INSTANCE_ID" "${AWS_INSTANCE_ID}"
fi

# Wait for the instance to reach running state
log "  Waiting for instance to reach 'running' state (bare-metal instances take 3-5 min) ..."
aws ec2 wait instance-running \
    --instance-ids "${AWS_INSTANCE_ID}"
ok "  Instance is running."

# Wait for both system and instance status checks to pass.
# aws ec2 wait instance-status-ok has a built-in 40 attempt * 15s = 10 min timeout.
log "  Waiting for status checks to pass ..."
aws ec2 wait instance-status-ok \
    --instance-ids "${AWS_INSTANCE_ID}"
ok "  Status checks passed."

# Give cloud-init time to finish injecting the SSH key and starting sshd.
# Status checks pass when the EC2 hypervisor is happy, but the OS may still
# be running cloud-init. On a1.metal this gap is typically 30-90 seconds.
log "  Giving cloud-init time to finish (60s) ..."
sleep 60
ok "  Grace period done."

# ---------------------------------------------------------------------------
# Elastic IP — allocate once and associate with the instance so the public
# IP never changes across stop/start cycles or reboots.  This also means
# the security group SSH rule never needs updating for IP drift.
# ---------------------------------------------------------------------------
log "  Setting up Elastic IP ..."

if [[ -n "${AWS_EIP_ID}" ]]; then
    # Verify the recorded EIP still exists
    EIP_EXISTS=$(aws ec2 describe-addresses \
        --allocation-ids "${AWS_EIP_ID}" \
        --query 'Addresses[0].AllocationId' \
        --output text 2>/dev/null || true)
    [[ "${EIP_EXISTS}" == "None" || -z "${EIP_EXISTS}" ]] && AWS_EIP_ID=""
fi

if [[ -z "${AWS_EIP_ID}" ]]; then
    # Check for an existing tagged EIP first (idempotent re-runs)
    AWS_EIP_ID=$(aws ec2 describe-addresses \
        --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
        --query 'Addresses[0].AllocationId' \
        --output text 2>/dev/null || true)
    [[ "${AWS_EIP_ID}" == "None" ]] && AWS_EIP_ID=""
fi

if [[ -z "${AWS_EIP_ID}" ]]; then
    log "  Allocating new Elastic IP ..."
    AWS_EIP_ID=$(aws ec2 allocate-address \
        --domain vpc \
        --query 'AllocationId' \
        --output text)
    aws ec2 create-tags \
        --resources "${AWS_EIP_ID}" \
        --tags "Key=Name,Value=${NAME_TAG}" "Key=${TAG_KEY},Value=${TAG_VALUE}"
    ok "  Allocated Elastic IP: ${AWS_EIP_ID}"
    env_set "AWS_EIP_ID" "${AWS_EIP_ID}"
else
    ok "  Reusing existing Elastic IP: ${AWS_EIP_ID}"
fi

# Associate the EIP with the instance (idempotent — re-associating is safe)
log "  Associating Elastic IP with instance ${AWS_INSTANCE_ID} ..."
aws ec2 associate-address \
    --instance-id "${AWS_INSTANCE_ID}" \
    --allocation-id "${AWS_EIP_ID}" \
    --allow-reassociation &>/dev/null
ok "  Elastic IP associated."

# Retrieve the now-stable public IP from the EIP
INSTANCE_PUBLIC_IP=$(aws ec2 describe-addresses \
    --allocation-ids "${AWS_EIP_ID}" \
    --query 'Addresses[0].PublicIp' \
    --output text)

[[ -z "${INSTANCE_PUBLIC_IP}" || "${INSTANCE_PUBLIC_IP}" == "None" ]] && \
    die "Could not retrieve public IP from Elastic IP ${AWS_EIP_ID}."

ok "  Public IP (Elastic): ${INSTANCE_PUBLIC_IP}"

# Write SSH connection details immediately — these are known now and should
# not depend on the EBS device detection that follows succeeding.
log "Writing SSH config to ${ENV_FILE} ..."
env_set "REMOTE_HOST"     "${INSTANCE_PUBLIC_IP}"
env_set "REMOTE_USER"     "${REMOTE_USER}"
env_set "REMOTE_PEM"      "${AWS_PEM_PATH}"
env_set "REMOTE_WORK_DIR" "${REMOTE_WORK_DIR}"
ok "SSH config written — you can already ssh in with: ssh -i ${AWS_PEM_PATH} ${REMOTE_USER}@${INSTANCE_PUBLIC_IP}"

# ---------------------------------------------------------------------------
# Step 8: EBS data volume for ZFS
# ---------------------------------------------------------------------------
log "Step 8/9 — EBS ZFS data volume ..."

# The instance's AZ
INSTANCE_AZ=$(aws ec2 describe-instances \
    --instance-ids "${AWS_INSTANCE_ID}" \
    --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' \
    --output text)

# Check if a tagged data volume is already attached to this instance
ATTACHED_VOL=$(aws ec2 describe-volumes \
    --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
              "Name=attachment.instance-id,Values=${AWS_INSTANCE_ID}" \
    --query 'Volumes[0].VolumeId' \
    --output text 2>/dev/null || true)
[[ "$ATTACHED_VOL" == "None" ]] && ATTACHED_VOL=""

if [[ -n "${ATTACHED_VOL}" ]]; then
    ok "  Data volume ${ATTACHED_VOL} already attached to ${AWS_INSTANCE_ID}."
    DATA_VOL_ID="${ATTACHED_VOL}"
else
    # Check for an existing unattached tagged volume
    FREE_VOL=$(aws ec2 describe-volumes \
        --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
                  "Name=status,Values=available" \
                  "Name=availability-zone,Values=${INSTANCE_AZ}" \
        --query 'Volumes[0].VolumeId' \
        --output text 2>/dev/null || true)
    [[ "$FREE_VOL" == "None" ]] && FREE_VOL=""

    if [[ -n "${FREE_VOL}" ]]; then
        DATA_VOL_ID="${FREE_VOL}"
        ok "  Found existing unattached volume ${DATA_VOL_ID} — will attach it."
    else
        log "  Creating ${AWS_EBS_SIZE_GB} GB ${AWS_EBS_TYPE} volume in ${INSTANCE_AZ} ..."
        DATA_VOL_ID=$(aws ec2 create-volume \
            --availability-zone "${INSTANCE_AZ}" \
            --size "${AWS_EBS_SIZE_GB}" \
            --volume-type "${AWS_EBS_TYPE}" \
            --tag-specifications \
                "ResourceType=volume,Tags=[{Key=Name,Value=${NAME_TAG}-zfs},{Key=${TAG_KEY},Value=${TAG_VALUE}}]" \
            --query 'VolumeId' \
            --output text)

        # Wait for the volume to become available
        aws ec2 wait volume-available \
            --volume-ids "${DATA_VOL_ID}"

        ok "  Created volume: ${DATA_VOL_ID}"
    fi

    # Attach the volume as /dev/sdf (shows up as /dev/nvme1n1 on Nitro/a1.metal)
    log "  Attaching ${DATA_VOL_ID} to ${AWS_INSTANCE_ID} as /dev/sdf ..."
    aws ec2 attach-volume \
        --volume-id "${DATA_VOL_ID}" \
        --instance-id "${AWS_INSTANCE_ID}" \
        --device /dev/sdf &>/dev/null

    aws ec2 wait volume-in-use \
        --volume-ids "${DATA_VOL_ID}"

    ok "  Volume attached."
fi

# ---------------------------------------------------------------------------
# Determine the block device name as seen by the OS on a1.metal (Nitro)
# ---------------------------------------------------------------------------
# a1.metal uses the Nitro hypervisor, so EBS volumes presented as /dev/sdf
# appear inside the OS as NVMe devices.  The root volume is /dev/nvme0n1;
# the first additional volume is /dev/nvme1n1.
#
# We SSH in and ask the instance directly — this is the only reliable way
# because the NVMe index order can vary if multiple volumes are attached.
# ---------------------------------------------------------------------------
log "Detecting block device name on the instance ..."

SSH_OPTS=(
    -i "${AWS_PEM_PATH}"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=15
    -o ServerAliveInterval=10
)

# Wait until SSH is actually accepting connections.
# Bare-metal boot + cloud-init can take 8-10 min total; poll for up to 20 min
# (120 attempts * 10s) so a slow first boot doesn't cause a spurious failure.
log "Waiting for SSH to become available on ${INSTANCE_PUBLIC_IP} ..."
ATTEMPTS=0
MAX_ATTEMPTS=120
until ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${INSTANCE_PUBLIC_IP}" "echo ok" &>/dev/null; do
    ATTEMPTS=$(( ATTEMPTS + 1 ))
    if [[ $ATTEMPTS -ge $MAX_ATTEMPTS ]]; then
        die "SSH not available after $(( MAX_ATTEMPTS * 10 / 60 )) min. \
Check the instance console: aws ec2 get-console-output --instance-id ${AWS_INSTANCE_ID}"
    fi
    ELAPSED=$(( ATTEMPTS * 10 ))
    printf "  waiting for sshd ... %dm%02ds elapsed (attempt %d/%d)\r" \
        "$(( ELAPSED / 60 ))" "$(( ELAPSED % 60 ))" "$ATTEMPTS" "$MAX_ATTEMPTS"
    sleep 10
done
echo ""
ok "SSH is available."

# Find the NVMe device that corresponds to our EBS volume by matching the
# EBS volume ID embedded in the NVMe serial number (Nitro puts it there).
# Falls back to picking the non-root NVMe disk if nvme-cli is absent.
# Pre-initialize so the variable is always bound even if the ssh command fails,
# which would otherwise trigger "unbound variable" under set -u before we can
# print a helpful error message.
POOL_DEVICE=""

POOL_DEVICE=$(ssh "${SSH_OPTS[@]}" "${REMOTE_USER}@${INSTANCE_PUBLIC_IP}" bash <<'REMOTE' || true
# Only the final `echo` writes to stdout — everything else goes to stderr so
# that apt/nvme diagnostic output is never captured into POOL_DEVICE.

VOL_SUFFIX=""

# Install nvme-cli if needed (it ships the 'nvme' command).
# All output redirected to stderr; failure is non-fatal — we have a lsblk fallback.
if ! command -v nvme &>/dev/null; then
    sudo apt-get install -y -qq nvme-cli >/dev/stderr 2>&1 || true
fi

if command -v nvme &>/dev/null; then
    # Each Nitro NVMe device has a serial number like "vol0123456789abcdef0".
    # We want any device that is NOT the root volume (/dev/nvme0n1).
    for dev in /dev/nvme1n1 /dev/nvme2n1 /dev/nvme3n1; do
        [[ -b "$dev" ]] || continue
        serial=$(sudo nvme id-ctrl "$dev" 2>/dev/null | awk '/^sn /{print $3}' || true)
        if [[ -n "$serial" ]]; then
            VOL_SUFFIX="$dev"
            echo "nvme: found data volume at ${dev} (serial: ${serial})" >&2
            break
        fi
    done
fi

# Fallback: lsblk — pick the first non-root disk
if [[ -z "$VOL_SUFFIX" ]]; then
    VOL_SUFFIX=$(lsblk -dn -o NAME,TYPE 2>/dev/null \
        | awk '$2=="disk" && $1!="nvme0n1" {print "/dev/"$1; exit}' || true)
    [[ -n "$VOL_SUFFIX" ]] && echo "lsblk fallback: found data volume at ${VOL_SUFFIX}" >&2
fi

# Only this line goes to stdout — it is what gets captured into POOL_DEVICE
echo "$VOL_SUFFIX"
REMOTE
)

if [[ -z "${POOL_DEVICE}" ]]; then
    warn "Could not auto-detect the ZFS data volume device on the instance."
    warn "The instance is reachable at ${INSTANCE_PUBLIC_IP}."
    warn "SSH in and run:  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT"
    warn "Then set REMOTE_POOL_DEVICE in ${ENV_FILE} manually before running vm-setup.sh."
    # Don't die — SSH config is already written; only REMOTE_POOL_DEVICE is missing.
else
    ok "ZFS pool device: ${POOL_DEVICE}"
fi

# ---------------------------------------------------------------------------
# Step 9: S3 bucket + IAM instance profile for ZFS diff save/restore
# ---------------------------------------------------------------------------
log "Step 9/9 — S3 bucket and IAM instance profile ..."

# Derive a default bucket name from the AWS account ID + region to ensure
# global uniqueness while remaining deterministic across re-runs.
if [[ -z "${AWS_S3_BUCKET}" ]]; then
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
    AWS_S3_BUCKET="fs-worker-diffs-${AWS_ACCOUNT_ID}-${AWS_REGION}"
fi

# Create the bucket if it doesn't already exist
if aws s3api head-bucket --bucket "${AWS_S3_BUCKET}" 2>/dev/null; then
    ok "  Reusing existing S3 bucket: ${AWS_S3_BUCKET}"
else
    log "  Creating S3 bucket: ${AWS_S3_BUCKET} ..."
    if [[ "${AWS_REGION}" == "us-east-1" ]]; then
        aws s3api create-bucket \
            --bucket "${AWS_S3_BUCKET}" \
            &>/dev/null
    else
        aws s3api create-bucket \
            --bucket "${AWS_S3_BUCKET}" \
            --create-bucket-configuration "LocationConstraint=${AWS_REGION}" \
            &>/dev/null
    fi

    # Block all public access
    aws s3api put-public-access-block \
        --bucket "${AWS_S3_BUCKET}" \
        --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    aws s3api put-bucket-tagging \
        --bucket "${AWS_S3_BUCKET}" \
        --tagging "TagSet=[{Key=Name,Value=${NAME_TAG}},{Key=${TAG_KEY},Value=${TAG_VALUE}}]"

    ok "  Created S3 bucket: ${AWS_S3_BUCKET}"
fi

env_set "AWS_S3_BUCKET" "${AWS_S3_BUCKET}"

# ---------------------------------------------------------------------------
# IAM role + instance profile so the EC2 instance can read/write the bucket
# ---------------------------------------------------------------------------
log "  Setting up IAM role and instance profile for S3 access ..."

# Create the IAM role if it doesn't exist
if aws iam get-role --role-name "${AWS_IAM_ROLE_NAME}" &>/dev/null; then
    ok "  Reusing existing IAM role: ${AWS_IAM_ROLE_NAME}"
else
    log "  Creating IAM role: ${AWS_IAM_ROLE_NAME} ..."
    aws iam create-role \
        --role-name "${AWS_IAM_ROLE_NAME}" \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "ec2.amazonaws.com"},
                "Action": "sts:AssumeRole"
            }]
        }' \
        --tags "Key=Name,Value=${NAME_TAG}" "Key=${TAG_KEY},Value=${TAG_VALUE}" \
        &>/dev/null
    ok "  Created IAM role: ${AWS_IAM_ROLE_NAME}"
fi

# Attach an inline policy granting read/write to the specific bucket
log "  Attaching S3 read/write policy for bucket ${AWS_S3_BUCKET} ..."
aws iam put-role-policy \
    --role-name "${AWS_IAM_ROLE_NAME}" \
    --policy-name "fs-worker-s3-access" \
    --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [{
            \"Effect\": \"Allow\",
            \"Action\": [
                \"s3:GetObject\",
                \"s3:PutObject\",
                \"s3:DeleteObject\",
                \"s3:ListBucket\"
            ],
            \"Resource\": [
                \"arn:aws:s3:::${AWS_S3_BUCKET}\",
                \"arn:aws:s3:::${AWS_S3_BUCKET}/*\"
            ]
        }]
    }"
ok "  S3 policy attached."

# Create the instance profile if it doesn't exist
if aws iam get-instance-profile --instance-profile-name "${AWS_INSTANCE_PROFILE}" &>/dev/null; then
    ok "  Reusing existing instance profile: ${AWS_INSTANCE_PROFILE}"
else
    log "  Creating instance profile: ${AWS_INSTANCE_PROFILE} ..."
    aws iam create-instance-profile \
        --instance-profile-name "${AWS_INSTANCE_PROFILE}" \
        --tags "Key=Name,Value=${NAME_TAG}" "Key=${TAG_KEY},Value=${TAG_VALUE}" \
        &>/dev/null

    aws iam add-role-to-instance-profile \
        --instance-profile-name "${AWS_INSTANCE_PROFILE}" \
        --role-name "${AWS_IAM_ROLE_NAME}"

    # IAM instance profiles take a few seconds to propagate
    log "  Waiting for instance profile to propagate (15s) ..."
    sleep 15
    ok "  Created instance profile: ${AWS_INSTANCE_PROFILE}"
fi

# Associate the instance profile with the EC2 instance (idempotent)
CURRENT_PROFILE=$(aws ec2 describe-iam-instance-profile-associations \
    --filters "Name=instance-id,Values=${AWS_INSTANCE_ID}" \
              "Name=state,Values=associated" \
    --query 'IamInstanceProfileAssociations[0].IamInstanceProfile.Arn' \
    --output text 2>/dev/null || true)

if [[ -n "${CURRENT_PROFILE}" && "${CURRENT_PROFILE}" != "None" ]]; then
    ok "  Instance already has an IAM instance profile associated."
else
    log "  Associating instance profile with instance ${AWS_INSTANCE_ID} ..."
    aws ec2 associate-iam-instance-profile \
        --instance-id "${AWS_INSTANCE_ID}" \
        --iam-instance-profile "Name=${AWS_INSTANCE_PROFILE}" &>/dev/null
    ok "  Instance profile associated with instance."
fi

# ---------------------------------------------------------------------------
# Write / update .env
# ---------------------------------------------------------------------------
log "Updating ${ENV_FILE} with ZFS device and instance ID ..."

[[ -n "${POOL_DEVICE}" ]] && env_set "REMOTE_POOL_DEVICE" "${POOL_DEVICE}"
env_set "AWS_INSTANCE_ID"    "${AWS_INSTANCE_ID}"

ok ".env updated."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
ok "============================================================"
ok "  ${AWS_INSTANCE_TYPE} instance is ready!"
ok ""
ok "  Instance ID : ${AWS_INSTANCE_ID}"
ok "  Public IP   : ${INSTANCE_PUBLIC_IP}"
ok "  Region      : ${AWS_REGION}"
ok "  ZFS device  : ${POOL_DEVICE}"
ok "  S3 bucket   : ${AWS_S3_BUCKET}"
ok "  IAM profile : ${AWS_INSTANCE_PROFILE}"
ok "  SSH key     : ${AWS_PEM_PATH}"
ok ""
ok "  .env has been updated — you can now run:"
ok ""
ok "    ./scripts/vm-setup.sh   # install ZFS, Rust, and the worker service"
ok "    ./scripts/vm-build.sh   # compile the worker binary"
ok "    ./scripts/vm-run.sh     # start the worker"
ok "    ./scripts/vm-shell.sh   # open a shell on the instance"
ok ""
ok "  To tear everything down:"
ok "    ./scripts/vm-provision.sh --destroy"
ok "============================================================"
