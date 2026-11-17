#!/usr/bin/env bash
#
# Delete the explore-kinesis-firehose CloudFormation stack.
#
# Empties ErrorBucket first: S3 refuses to delete a non-empty bucket, which
# would leave the stack in DELETE_FAILED. Works from any deletable state,
# including ROLLBACK_COMPLETE after a failed first create.
#
# Not touched: the exec role's LF grant (ALL with grant option on the
# namespace's tables) made by firehose.sh outside CloudFormation. It is
# re-applied on every deploy and disappears with the table bucket.
#
# Usage:
#   ./delete-firehose.sh                 # normal delete
#   ./delete-firehose.sh --retain <id>   # delete, retaining the named resource(s)
#                                        # repeat --retain for multiple resources
#
# Environment:
#   REGION   (optional) - defaults to eu-west-1
#   PROFILE  (optional) - AWS CLI profile to use

set -euo pipefail

# ---- Configuration ----------------------------------------------------------

STACK="explore-kinesis-firehose"
REGION="${REGION:-eu-west-1}"
PROFILE="${PROFILE:-}"

AWS_FLAGS=(--region "${REGION}" --no-cli-pager)
if [[ -n "${PROFILE}" ]]; then
    AWS_FLAGS+=(--profile "${PROFILE}")
fi

retain_resources=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --retain)
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: --retain requires a logical resource ID" >&2
                exit 1
            fi
            retain_resources+=("$2")
            shift 2
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "Usage: $0 [--retain <LogicalResourceId>]..." >&2
            exit 1
            ;;
    esac
done

# ---- Helpers ----------------------------------------------------------------

log() {
    printf '\n>>> %s\n' "$*"
}

# Print the stack's status, or DOES_NOT_EXIST. Any other describe-stacks
# failure (expired session, throttling, ...) is printed to stderr and
# returns non-zero, which aborts the script under set -e.
stack_status() {
    local err status
    err=$(mktemp)
    if status=$(aws cloudformation describe-stacks \
            "${AWS_FLAGS[@]}" \
            --stack-name "${STACK}" \
            --query 'Stacks[0].StackStatus' \
            --output text 2>"${err}"); then
        rm -f "${err}"
        echo "${status}"
    elif grep -q 'does not exist' "${err}"; then
        rm -f "${err}"
        echo "DOES_NOT_EXIST"
    else
        cat "${err}" >&2
        rm -f "${err}"
        return 1
    fi
}

# Unversioned bucket, so a recursive rm is enough. No-op if the resource
# was never created or the bucket is already gone.
empty_error_bucket() {
    local bucket
    bucket=$(aws cloudformation describe-stack-resource \
        "${AWS_FLAGS[@]}" \
        --stack-name "${STACK}" \
        --logical-resource-id ErrorBucket \
        --query 'StackResourceDetail.PhysicalResourceId' \
        --output text 2>/dev/null) || bucket=""

    if [[ -z "${bucket}" || "${bucket}" == "None" ]]; then
        echo "    no ErrorBucket in stack - nothing to empty"
        return 0
    fi
    if ! aws s3api head-bucket "${AWS_FLAGS[@]}" --bucket "${bucket}" >/dev/null 2>&1; then
        echo "    ${bucket} already gone - nothing to empty"
        return 0
    fi
    echo "    emptying s3://${bucket}"
    aws s3 rm "s3://${bucket}" --recursive --region "${REGION}" \
        ${PROFILE:+--profile "${PROFILE}"} --only-show-errors
}

# ---- Confirm credentials and stack existence --------------------------------

log "Resolving AWS account from active credentials"

account_id=$(aws sts get-caller-identity "${AWS_FLAGS[@]}" --query Account --output text)
echo "    account: ${account_id}"
echo "    region:  ${REGION}"
echo "    stack:   ${STACK}"

log "Checking current stack status"

stack_state=$(stack_status)
echo "    status: ${stack_state}"

case "${stack_state}" in
    DOES_NOT_EXIST|DELETE_COMPLETE)
        log "Stack does not exist - nothing to do."
        exit 0
        ;;
    DELETE_IN_PROGRESS)
        log "Stack delete already in progress - waiting for completion"
        ;;
esac

# ---- Issue delete -----------------------------------------------------------

if [[ "${stack_state}" != "DELETE_IN_PROGRESS" ]]; then
    log "Emptying error bucket"
    empty_error_bucket

    if (( ${#retain_resources[@]} > 0 )); then
        log "Deleting stack, retaining: ${retain_resources[*]}"
        aws cloudformation delete-stack \
            "${AWS_FLAGS[@]}" \
            --stack-name "${STACK}" \
            --retain-resources "${retain_resources[@]}"
    else
        log "Deleting stack"
        aws cloudformation delete-stack \
            "${AWS_FLAGS[@]}" \
            --stack-name "${STACK}"
    fi
fi

# ---- Wait for completion ----------------------------------------------------

log "Waiting for delete to complete (this can take a few minutes)"

if aws cloudformation wait stack-delete-complete \
        "${AWS_FLAGS[@]}" \
        --stack-name "${STACK}"; then
    log "Stack deleted successfully."
    exit 0
fi

# ---- Diagnose failure -------------------------------------------------------

final_state=$(stack_status)

log "Delete did not complete cleanly. Final status: ${final_state}"

echo
echo "Most recent failed events:"
aws cloudformation describe-stack-events \
    "${AWS_FLAGS[@]}" \
    --stack-name "${STACK}" \
    --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].[Timestamp,LogicalResourceId,ResourceStatusReason]" \
    --output table

echo
echo "If ErrorBucket failed with BucketNotEmpty, Firehose wrote late records - re-run."
echo "To skip a stuck resource, re-run with: --retain <LogicalResourceId>"
exit 1
