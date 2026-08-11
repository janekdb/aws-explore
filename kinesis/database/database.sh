#!/usr/bin/env bash
#
# Deploy the explore-kinesis database stack.
#
# Prerequisites:
#   - AWS CLI authenticated with credentials that can pass the CFN exec role
#   - explore-kinesis-cfn-bootstrap stack already deployed (provides the CFN exec role)
#
# Environment:
#   REGION       (optional) - defaults to eu-west-1
#   PROFILE      (optional) - AWS CLI profile to use

set -euo pipefail

# ---- Configuration ----------------------------------------------------------

REGION="${REGION:-eu-west-1}"
PROFILE="${PROFILE:-}"

STACK="explore-kinesis-database"
BOOTSTRAP_STACK="explore-kinesis-cfn-bootstrap"

# Resolve paths relative to this script so it works from any cwd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/database.yaml"

AWS_FLAGS=(--region "${REGION}")
if [[ -n "${PROFILE}" ]]; then
    AWS_FLAGS+=(--profile "${PROFILE}")
fi

# ---- Helpers ----------------------------------------------------------------

log() {
    printf '\n>>> %s\n' "$*"
}

# ---- Resolve exec role from bootstrap stack ----------------------------------

log "Resolving exec role ARN from ${BOOTSTRAP_STACK}"

ROLE_ARN=$(aws cloudformation describe-stacks \
    "${AWS_FLAGS[@]}" \
    --stack-name "${BOOTSTRAP_STACK}" \
    --query "Stacks[0].Outputs[?OutputKey=='RoleArn'].OutputValue" \
    --output text)

if [[ -z "${ROLE_ARN}" || "${ROLE_ARN}" == "None" ]]; then
    echo "ERROR: could not resolve RoleArn from ${BOOTSTRAP_STACK}" >&2
    echo "       Is the bootstrap stack deployed and exporting that output?" >&2
    exit 1
fi

echo "    exec role: ${ROLE_ARN}"
echo "    region:    ${REGION}"

# ---- Validate template ------------------------------------------------------

log "Validating ${TEMPLATE}"

aws cloudformation validate-template \
    "${AWS_FLAGS[@]}" \
    --template-body "file://${TEMPLATE}" \
    >/dev/null

echo "    template is well-formed"

# ---- Deploy -----------------------------------------------------------------

log "Deploying ${STACK} via exec role"

aws cloudformation deploy \
    "${AWS_FLAGS[@]}" \
    --template-file "${TEMPLATE}" \
    --stack-name "${STACK}" \
    --role-arn "${ROLE_ARN}" \
    --tags project=explore-kinesis \
    --no-fail-on-empty-changeset

# ---- Summary ----------------------------------------------------------------

log "Stack outputs"

aws cloudformation describe-stacks \
    "${AWS_FLAGS[@]}" \
    --stack-name "${STACK}" \
    --query "Stacks[0].Outputs" \
    --output table

log "Done."
