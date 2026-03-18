#!/usr/bin/env bash
# =============================================================================
# vm-ssh-allow.sh — Update the security group to allow SSH from your current IP
#
# Your EC2 security group is locked to the IP you had when vm-provision.sh ran.
# If your IP has changed (different network, ISP reassignment, VPN, etc.) all
# SSH-based scripts will time out.  Run this script to fix it.
#
# Usage:
#   ./scripts/vm-ssh-allow.sh
#
# Reads from .env:
#   AWS_SG_ID      Security group to update        (required)
#   AWS_REGION     AWS region                       (default: us-east-1)
#   AWS_PROFILE    AWS CLI named profile            (optional)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PREFIX="[vm-ssh-allow]"
source "${SCRIPT_DIR}/lib.sh"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v aws &>/dev/null \
    || die "AWS CLI not found. Install it: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"

[[ -n "${AWS_SG_ID}" ]] \
    || die "AWS_SG_ID is not set. Run vm-provision.sh first or set it in ${ENV_FILE}."

# ---------------------------------------------------------------------------
# aws wrapper (same pattern as vm-provision.sh)
# ---------------------------------------------------------------------------
aws() {
    local args=()
    [[ -n "${AWS_PROFILE:-}" ]] && args+=(--profile "${AWS_PROFILE}")
    args+=(--region "${AWS_REGION}")
    command aws "${args[@]}" "$@"
}

# ---------------------------------------------------------------------------
# Resolve current public IP
# ---------------------------------------------------------------------------
log "Resolving your current public IP ..."

MY_IP=$(curl -sf https://checkip.amazonaws.com \
     || curl -sf https://api.ipify.org \
     || true)

[[ -z "${MY_IP}" ]] && die "Could not determine your public IP. Check your internet connection."

MY_CIDR="${MY_IP}/32"
ok "Current public IP: ${MY_IP}"

# ---------------------------------------------------------------------------
# Show existing SSH rules so it's clear what is being replaced
# ---------------------------------------------------------------------------
log "Existing SSH ingress rules on ${AWS_SG_ID} ..."

EXISTING_RULES=$(aws ec2 describe-security-groups \
    --group-ids "${AWS_SG_ID}" \
    --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\`].IpRanges[*].CidrIp" \
    --output text 2>/dev/null || true)

if [[ -z "${EXISTING_RULES}" || "${EXISTING_RULES}" == "None" ]]; then
    log "  (no existing SSH rules)"
else
    for cidr in ${EXISTING_RULES}; do
        if [[ "${cidr}" == "${MY_CIDR}" ]]; then
            ok "  ${cidr}  ← already matches your current IP"
        else
            log "  ${cidr}"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Skip if the rule already exists
# ---------------------------------------------------------------------------
if echo "${EXISTING_RULES}" | grep -qF "${MY_CIDR}"; then
    ok "Security group already allows SSH from ${MY_CIDR} — nothing to do."
    exit 0
fi

# ---------------------------------------------------------------------------
# Revoke stale rules (optional but keeps the SG clean — only removes CIDRs
# that are a single /32, i.e. previous personal IPs, not broad ranges)
# ---------------------------------------------------------------------------
for cidr in ${EXISTING_RULES}; do
    # Only revoke single-host /32 rules — leave any broader ranges alone
    if [[ "${cidr}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32$ && "${cidr}" != "${MY_CIDR}" ]]; then
        log "Revoking stale SSH rule: ${cidr} ..."
        aws ec2 revoke-security-group-ingress \
            --group-id "${AWS_SG_ID}" \
            --protocol tcp \
            --port 22 \
            --cidr "${cidr}" 2>/dev/null && ok "  Revoked ${cidr}." \
            || warn "  Could not revoke ${cidr} (may already be gone)."
    fi
done

# ---------------------------------------------------------------------------
# Add rule for current IP
# ---------------------------------------------------------------------------
log "Adding SSH ingress rule for ${MY_CIDR} ..."

aws ec2 authorize-security-group-ingress \
    --group-id "${AWS_SG_ID}" \
    --protocol tcp \
    --port 22 \
    --cidr "${MY_CIDR}"

ok "SSH (port 22) is now open to ${MY_CIDR}."

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
ok "============================================================"
ok "  Security group ${AWS_SG_ID} updated."
ok "  Your IP : ${MY_IP}"
ok ""
ok "  You can now run:"
ok "    ./scripts/vm-setup.sh    # if setup was interrupted"
ok "    ./scripts/vm-shell.sh    # open a shell on the instance"
ok "    ./scripts/vm-build.sh    # compile the worker"
ok "============================================================"
