#!/usr/bin/env bash
#
# Package and deploy the explore-kinesis application stack.
#
# Prerequisites:
#   - AWS CLI authenticated with credentials that can assume the CFN exec role
#   - explore-kinesis-storage stack already deployed (provides inputs + artifacts buckets)
#   - explore-kinesis-bootstrap stack already deployed (provides the CFN exec role)
#
# Environment:
#   REGION       (optional) - defaults to eu-west-1
#   PROFILE      (optional) - AWS CLI profile to use
#
# The AWS account ID is discovered automatically from the active credentials.

set -euo pipefail

# ---- Configuration ----------------------------------------------------------

REGION="${REGION:-eu-west-1}"
PROFILE="${PROFILE:-}"

STACK="explore-kinesis-app"
STORAGE_STACK="explore-kinesis-storage"

# Resolve paths relative to this script so it works from any cwd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${SCRIPT_DIR}/../app"
TEMPLATE="${APP_DIR}/app.yaml"
PACKAGED="${APP_DIR}/packaged.yaml"
SRC_DIR="${APP_DIR}/src/data_generator"
REQUIREMENTS="${SRC_DIR}/requirements.txt"

AWS_FLAGS=(--region "${REGION}")
if [[ -n "${PROFILE}" ]]; then
    AWS_FLAGS+=(--profile "${PROFILE}")
fi

# ---- Helpers ----------------------------------------------------------------

log() {
    printf '\n>>> %s\n' "$*"
}

# ---- Discover account ID from active credentials ----------------------------

log "Resolving AWS account from active credentials"

ACCOUNT_ID=$(aws sts get-caller-identity "${AWS_FLAGS[@]}" --query Account --output text)

if [[ -z "${ACCOUNT_ID}" || "${ACCOUNT_ID}" == "None" ]]; then
    echo "ERROR: could not resolve account ID from sts:GetCallerIdentity" >&2
    echo "       Are AWS credentials configured? (env vars, profile, or instance role)" >&2
    exit 1
fi

EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/explore-kinesis-cfn-exec"

echo "    account: ${ACCOUNT_ID}"
echo "    region:  ${REGION}"

# ---- Resolve artifacts bucket from storage stack ----------------------------

log "Resolving artifacts bucket from ${STORAGE_STACK}"

ARTIFACTS_BUCKET=$(aws cloudformation describe-stacks \
    "${AWS_FLAGS[@]}" \
    --stack-name "${STORAGE_STACK}" \
    --query "Stacks[0].Outputs[?OutputKey=='ArtifactBucketName'].OutputValue" \
    --output text)

if [[ -z "${ARTIFACTS_BUCKET}" || "${ARTIFACTS_BUCKET}" == "None" ]]; then
    echo "ERROR: could not resolve ArtifactBucketName from ${STORAGE_STACK}" >&2
    echo "       Is the storage stack deployed and exporting that output?" >&2
    exit 1
fi

echo "    artifacts bucket: ${ARTIFACTS_BUCKET}"

# ---- Install Python dependencies (if any) -----------------------------------

if [[ -s "${REQUIREMENTS}" ]]; then
    log "Installing Python dependencies into ${SRC_DIR}"
    pip install \
        --target "${SRC_DIR}" \
        --requirement "${REQUIREMENTS}" \
        --platform manylinux2014_aarch64 \
        --only-binary=:all: \
        --upgrade \
        --quiet
else
    log "No requirements.txt found at ${REQUIREMENTS} - skipping dependency install"
fi

# ---- Validate template ------------------------------------------------------

log "Validating ${TEMPLATE}"

aws cloudformation validate-template \
    "${AWS_FLAGS[@]}" \
    --template-body "file://${TEMPLATE}" \
    >/dev/null

echo "    template is well-formed"

# ---- Package ----------------------------------------------------------------

log "Packaging Lambda code to s3://${ARTIFACTS_BUCKET}/${STACK}/"

aws cloudformation package \
    "${AWS_FLAGS[@]}" \
    --template-file "${TEMPLATE}" \
    --s3-bucket "${ARTIFACTS_BUCKET}" \
    --s3-prefix "${STACK}" \
    --output-template-file "${PACKAGED}"

# ---- Deploy -----------------------------------------------------------------

log "Deploying ${STACK} via exec role"

aws cloudformation deploy \
    "${AWS_FLAGS[@]}" \
    --template-file "${PACKAGED}" \
    --stack-name "${STACK}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --role-arn "${EXEC_ROLE_ARN}" \
    --tags project=explore-kinesis \
    --no-fail-on-empty-changeset

# ---- Grab the publisher ARN the app stack just exported
PUB_ARN=$(aws cloudformation describe-stacks --stack-name explore-kinesis-app \
  --region eu-west-1 \
  --query "Stacks[0].Outputs[?OutputKey=='PublisherFunctionArn'].OutputValue" --output text)

log "PublisherFunctionArn: ${PUB_ARN}"

# ---- Summary ----------------------------------------------------------------

log "Stack outputs"

aws cloudformation describe-stacks \
    "${AWS_FLAGS[@]}" \
    --stack-name "${STACK}" \
    --query "Stacks[0].Outputs" \
    --output table

log "Done."