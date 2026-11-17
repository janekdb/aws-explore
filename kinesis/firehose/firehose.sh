#!/usr/bin/env bash
#
# Deploy the explore-kinesis firehose stack:
#   Kinesis stream -> Amazon Data Firehose -> Iceberg table in S3 Tables.
#
# Prerequisites:
#   - AWS CLI authenticated as a Lake Formation data lake admin (for the
#     LF grant step) with credentials that can pass the CFN exec role
#   - jq on PATH
#   - explore-kinesis-cfn-bootstrap, -storage and -database stacks deployed
#   - S3 Tables <-> AWS analytics services integration enabled in REGION
#     (creates the federated Glue catalog 's3tablescatalog'; one-time, console:
#      S3 -> Table buckets -> Enable integration)
#
# What this script does beyond `cloudformation deploy`:
#   Grants the CFN exec role ALL, with grant option, on every table in the
#   namespace (TableWildcard), so the AWS::LakeFormation::PrincipalPermissions
#   resource in firehose.yaml can pass table access on to the Firehose role.
#   Granting is an LF permission, not only an IAM one: the exec role also
#   needs lakeformation:GrantPermissions etc. in its IAM policy
#   (iam-bootstrap.yaml).
#
#   Deliberately NOT a data lake admin: admin could grant anything on any
#   catalog in the account, and would outlive the stacks. This grant is
#   scoped to one namespace in one table bucket, covers tables added to the
#   namespace later (content-based routing), and disappears with the table
#   bucket. grant-permissions is idempotent, so it runs on every deploy -
#   needed because recreating the database stack drops LF grants.
#
# Environment:
#   REGION       (optional) - defaults to eu-west-1
#   PROFILE      (optional) - AWS CLI profile to use

set -euo pipefail

# ---- Configuration ----------------------------------------------------------

REGION="${REGION:-eu-west-1}"
PROFILE="${PROFILE:-}"

STACK="explore-kinesis-firehose"
BOOTSTRAP_STACK="explore-kinesis-cfn-bootstrap"
UPSTREAM_STACKS=(explore-kinesis-storage explore-kinesis-database)
S3TABLES_CATALOG="s3tablescatalog"

# Resolve paths relative to this script so it works from any cwd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/firehose.yaml"

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

# ---- Resolve exec role from bootstrap stack ----------------------------------

log "Resolving exec role ARN from ${BOOTSTRAP_STACK}"

ROLE_ARN=$(aws cloudformation describe-stacks \
    "${AWS_FLAGS[@]}" \
    --stack-name "${BOOTSTRAP_STACK}" \
    --query "Stacks[0].Outputs[?OutputKey=='RoleArn'].OutputValue" \
    --output text)

if [[ -z "${ROLE_ARN}" || "${ROLE_ARN}" == "None" ]]; then
    die "could not resolve RoleArn from ${BOOTSTRAP_STACK} - is it deployed?"
fi

echo "    exec role: ${ROLE_ARN}"
echo "    region:    ${REGION}"

# ---- Preflight: upstream stacks ---------------------------------------------

log "Checking upstream stacks (firehose.yaml imports from these)"

for S in "${UPSTREAM_STACKS[@]}"; do
    STATUS=$(aws cloudformation describe-stacks \
        "${AWS_FLAGS[@]}" \
        --stack-name "${S}" \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null) || STATUS="DOES_NOT_EXIST"
    echo "    ${S}: ${STATUS}"
    case "${STATUS}" in
        CREATE_COMPLETE|UPDATE_COMPLETE) ;;
        *) die "${S} is ${STATUS} - deploy it before the firehose stack" ;;
    esac
done

# ---- Preflight: S3 Tables analytics integration ------------------------------

log "Checking Glue catalog '${S3TABLES_CATALOG}' exists (S3 Tables integration)"

if ! aws glue get-catalog \
        "${AWS_FLAGS[@]}" \
        --catalog-id "${S3TABLES_CATALOG}" \
        >/dev/null 2>&1; then
    die "Glue catalog '${S3TABLES_CATALOG}' not found in ${REGION}.
       Enable S3 Tables integration with AWS analytics services (one-time):
       console -> S3 -> Table buckets -> Enable integration"
fi

echo "    integration enabled"

# ---- Lake Formation: grantable access for the exec role ----------------------

log "Resolving table location from explore-kinesis-database"

db_output() {
    aws cloudformation describe-stacks \
        "${AWS_FLAGS[@]}" \
        --stack-name explore-kinesis-database \
        --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
        --output text
}

ACCOUNT_ID=$(aws sts get-caller-identity "${AWS_FLAGS[@]}" --query Account --output text)
TABLE_BUCKET=$(db_output TableBucketName)
NAMESPACE=$(db_output NamespaceName)

for V in ACCOUNT_ID TABLE_BUCKET NAMESPACE; do
    if [[ -z "${!V}" || "${!V}" == "None" ]]; then
        die "could not resolve ${V}"
    fi
done

CATALOG_ID="${ACCOUNT_ID}:${S3TABLES_CATALOG}/${TABLE_BUCKET}"
echo "    catalog:   ${CATALOG_ID}"
echo "    namespace: ${NAMESPACE}"

log "Granting exec role ALL (with grant option) on ${NAMESPACE}.* tables"

LF_RESOURCE=$(jq -n \
    --arg catalog "${CATALOG_ID}" \
    --arg db "${NAMESPACE}" \
    '{Table: {CatalogId: $catalog, DatabaseName: $db, TableWildcard: {}}}')

aws lakeformation grant-permissions \
    "${AWS_FLAGS[@]}" \
    --principal DataLakePrincipalIdentifier="${ROLE_ARN}" \
    --resource "${LF_RESOURCE}" \
    --permissions ALL \
    --permissions-with-grant-option ALL

echo "    granted"

# Experiment (2026-10-28): CFN's table grant to the Firehose role failed with
# "Insufficient Glue permissions to access table readings" although the exec
# role's IAM allows glue:Get{Catalog,Database,Table} on every level. Hypothesis:
# in the multi-level S3 Tables catalog the grantor also needs LF DESCRIBE on
# the parent catalog and database to see the table. With grant option so the
# template can pass DESCRIBE on to the Firehose role if that turns out necessary.

log "Granting exec role DESCRIBE (with grant option) on catalog and ${NAMESPACE} database"

aws lakeformation grant-permissions \
    "${AWS_FLAGS[@]}" \
    --principal DataLakePrincipalIdentifier="${ROLE_ARN}" \
    --resource "$(jq -n --arg id "${CATALOG_ID}" '{Catalog: {Id: $id}}')" \
    --permissions DESCRIBE \
    --permissions-with-grant-option DESCRIBE

aws lakeformation grant-permissions \
    "${AWS_FLAGS[@]}" \
    --principal DataLakePrincipalIdentifier="${ROLE_ARN}" \
    --resource "$(jq -n --arg catalog "${CATALOG_ID}" --arg db "${NAMESPACE}" \
        '{Database: {CatalogId: $catalog, Name: $db}}')" \
    --permissions DESCRIBE \
    --permissions-with-grant-option DESCRIBE

echo "    granted"

# ---- Validate template ------------------------------------------------------

log "Validating ${TEMPLATE}"

aws cloudformation validate-template \
    "${AWS_FLAGS[@]}" \
    --template-body "file://${TEMPLATE}" \
    >/dev/null

echo "    template is well-formed"

# ---- Deploy -----------------------------------------------------------------

log "Deploying ${STACK} via exec role"

# CAPABILITY_NAMED_IAM: FirehoseRole has an explicit RoleName
aws cloudformation deploy \
    "${AWS_FLAGS[@]}" \
    --template-file "${TEMPLATE}" \
    --stack-name "${STACK}" \
    --role-arn "${ROLE_ARN}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --tags project=explore-kinesis \
    --no-fail-on-empty-changeset

# ---- Summary ----------------------------------------------------------------

log "Delivery stream status"

aws firehose describe-delivery-stream \
    "${AWS_FLAGS[@]}" \
    --delivery-stream-name explore-kinesis-weather \
    --query 'DeliveryStreamDescription.{Status:DeliveryStreamStatus,Source:Source.KinesisStreamSourceDescription.KinesisStreamARN}' \
    --output table

log "Done."
