#!/usr/bin/env bash
#
# Put the S3 Tables federated catalog (s3tablescatalog) under Lake Formation
# access control, so table access is decided by LF grants (e.g. the
# FirehoseTableGrant in firehose.yaml) rather than by IAM alone.
#
# Account-level, one-time setup - like enabling the S3 Tables <-> analytics
# integration in the console - but idempotent, so safe to re-run.
#
# Steps:
#   1. Deploy explore-kinesis-lake-formation: the IAM role Lake Formation
#      assumes to vend scoped credentials for S3 Tables data.
#   2. Register arn:aws:s3tables:REGION:ACCOUNT:bucket/* with Lake Formation,
#      with federation, using that role. Skipped if already registered;
#      aborts if registered with another role or with hybrid access.
#   3. Empty the catalog's CreateDatabaseDefaultPermissions and
#      CreateTableDefaultPermissions (removes IAM_ALLOWED_PRINCIPALS), so new
#      namespaces and tables are governed by LF grants only.
#
# Step 3 affects only namespaces/tables created afterwards. Ones that already
# exist keep their IAM_ALLOWED_PRINCIPALS grant: recreate the database stack
# after the first run.
#
# Run before database.sh and firehose.sh.
#
# Prerequisites:
#   - AWS CLI authenticated as a Lake Formation data lake admin with IAM
#     rights to create the role (deployed with your credentials, not the
#     CFN exec role: this role is account-level and has no boundary)
#   - jq on PATH
#   - S3 Tables <-> AWS analytics services integration enabled in REGION
#     (creates the Glue catalog 's3tablescatalog')
#
# Note: the Data Catalog settings page in the LF console ("Use only IAM access
# control for new databases/tables") governs the default catalog only - it
# does not change s3tablescatalog. Step 3 is what does.
#
# Environment:
#   REGION       (optional) - defaults to eu-west-1
#   PROFILE      (optional) - AWS CLI profile to use

set -euo pipefail

# ---- Configuration ----------------------------------------------------------

REGION="${REGION:-eu-west-1}"
PROFILE="${PROFILE:-}"

STACK="explore-kinesis-lake-formation"
S3TABLES_CATALOG="s3tablescatalog"
FULL_TABLE_EXTERNAL_ACCESS="False"   # AWS's example uses True; not needed for Firehose

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/lake-formation.yaml"

AWS_FLAGS=(--region "${REGION}" --no-cli-pager)
if [[ -n "${PROFILE}" ]]; then
    AWS_FLAGS+=(--profile "${PROFILE}")
fi

# ---- Helpers ----------------------------------------------------------------

log() {
    printf '\n>>> %s\n' "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

command -v jq >/dev/null || die "jq is required"

# ---- Preflight --------------------------------------------------------------

log "Resolving account from active credentials"

ACCOUNT_ID=$(aws sts get-caller-identity "${AWS_FLAGS[@]}" --query Account --output text)
CALLER_ARN=$(aws sts get-caller-identity "${AWS_FLAGS[@]}" --query Arn --output text)
RESOURCE_ARN="arn:aws:s3tables:${REGION}:${ACCOUNT_ID}:bucket/*"

echo "    account:  ${ACCOUNT_ID}"
echo "    caller:   ${CALLER_ARN}"
echo "    region:   ${REGION}"
echo "    resource: ${RESOURCE_ARN}"

log "Checking Glue catalog '${S3TABLES_CATALOG}' exists (S3 Tables integration)"

if ! aws glue get-catalog "${AWS_FLAGS[@]}" --catalog-id "${S3TABLES_CATALOG}" >/dev/null 2>&1; then
    die "Glue catalog '${S3TABLES_CATALOG}' not found in ${REGION}.
       Enable S3 Tables integration with AWS analytics services (one-time):
       console -> S3 -> Table buckets -> Enable integration"
fi

echo "    integration enabled"

# ---- Step 1: role -----------------------------------------------------------

log "Validating ${TEMPLATE}"

aws cloudformation validate-template \
    "${AWS_FLAGS[@]}" \
    --template-body "file://${TEMPLATE}" \
    >/dev/null

echo "    template is well-formed"

log "Deploying ${STACK} (your credentials, not the exec role)"

# CAPABILITY_NAMED_IAM: the role has an explicit RoleName
aws cloudformation deploy \
    "${AWS_FLAGS[@]}" \
    --template-file "${TEMPLATE}" \
    --stack-name "${STACK}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --tags project=explore-kinesis \
    --no-fail-on-empty-changeset

LF_ROLE_ARN=$(aws cloudformation describe-stacks \
    "${AWS_FLAGS[@]}" \
    --stack-name "${STACK}" \
    --query "Stacks[0].Outputs[?OutputKey=='RoleArn'].OutputValue" \
    --output text)

[[ -n "${LF_ROLE_ARN}" && "${LF_ROLE_ARN}" != "None" ]] || die "could not resolve RoleArn from ${STACK}"
echo "    role: ${LF_ROLE_ARN}"

# ---- Step 2: register with Lake Formation ------------------------------------

log "Registering ${RESOURCE_ARN} with Lake Formation (with federation)"

EXISTING=$(aws lakeformation list-resources \
    "${AWS_FLAGS[@]}" \
    --output json \
    | jq -c --arg arn "${RESOURCE_ARN}" \
        '.ResourceInfoList[] | select(.ResourceArn == $arn)')

if [[ -n "${EXISTING}" ]]; then
    echo "    already registered: ${EXISTING}"
    REG_ROLE=$(jq -r '.RoleArn // ""' <<<"${EXISTING}")
    REG_FED=$(jq -r '.WithFederation // false' <<<"${EXISTING}")
    REG_HYBRID=$(jq -r '.HybridAccessEnabled // false' <<<"${EXISTING}")
    [[ "${REG_ROLE}" == "${LF_ROLE_ARN}" ]] \
        || die "registered with role ${REG_ROLE}, expected ${LF_ROLE_ARN} - deregister first"
    [[ "${REG_FED}" == "true" ]] \
        || die "registered without federation - deregister and re-run"
    [[ "${REG_HYBRID}" == "false" ]] \
        || die "registered with hybrid access enabled - must be false"
    echo "    registration is as expected"
else
    # A just-created role can take a few seconds to become assumable.
    for ATTEMPT in 1 2 3 4 5 6; do
        if aws lakeformation register-resource \
                "${AWS_FLAGS[@]}" \
                --resource-arn "${RESOURCE_ARN}" \
                --role-arn "${LF_ROLE_ARN}" \
                --with-federation; then
            echo "    registered"
            break
        fi
        (( ATTEMPT < 6 )) || die "register-resource failed after ${ATTEMPT} attempts"
        echo "    attempt ${ATTEMPT} failed - retrying in 10s (IAM propagation?)"
        sleep 10
    done
fi

# ---- Step 3: remove IAM_ALLOWED_PRINCIPALS defaults ---------------------------

log "Updating ${S3TABLES_CATALOG}: empty default permissions (LF grants only)"

CATALOG_INPUT=$(jq -n \
    --arg id "${RESOURCE_ARN}" \
    --arg ext "${FULL_TABLE_EXTERNAL_ACCESS}" \
    '{
        FederatedCatalog: {Identifier: $id, ConnectionName: "aws:s3tables"},
        CreateDatabaseDefaultPermissions: [],
        CreateTableDefaultPermissions: [],
        AllowFullTableExternalDataAccess: $ext
    }')

aws glue update-catalog \
    "${AWS_FLAGS[@]}" \
    --catalog-id "${S3TABLES_CATALOG}" \
    --catalog-input "${CATALOG_INPUT}"

echo "    updated"

# ---- Verify -----------------------------------------------------------------

log "Lake Formation registration"

aws lakeformation list-resources \
    "${AWS_FLAGS[@]}" \
    --query "ResourceInfoList[?ResourceArn=='${RESOURCE_ARN}'].{Arn:ResourceArn,Role:RoleArn,Fed:WithFederation,Hybrid:HybridAccessEnabled}" \
    --output table

log "Catalog default permissions (expect both empty)"

DEFAULTS=$(aws glue get-catalog \
    "${AWS_FLAGS[@]}" \
    --catalog-id "${S3TABLES_CATALOG}" \
    --query 'Catalog.{DefDb:CreateDatabaseDefaultPermissions,DefTable:CreateTableDefaultPermissions}' \
    --output json)
echo "${DEFAULTS}"

[[ $(jq '(.DefDb // []) + (.DefTable // []) | length' <<<"${DEFAULTS}") -eq 0 ]] \
    || die "catalog still has default permissions"

log "Stack outputs"

aws cloudformation describe-stacks \
    "${AWS_FLAGS[@]}" \
    --stack-name "${STACK}" \
    --query "Stacks[0].Outputs" \
    --output table

log "Done. If the database stack predates this run, recreate it so its namespace and table lose IAM_ALLOWED_PRINCIPALS."
