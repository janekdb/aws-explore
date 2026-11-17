#!/usr/bin/env bash
#
# Undo lake-formation.sh: deregister the S3 Tables resource from Lake
# Formation, then delete the explore-kinesis-lake-formation stack (the role).
#
# Deregistering first matters: deleting the role while it is still
# registered leaves Lake Formation unable to vend credentials, with errors
# that do not name the missing role.
#
# Not touched: the s3tablescatalog default permissions stay empty. With the
# resource deregistered, S3 Tables data is reachable by no one until
# lake-formation.sh is re-run (or the IAM defaults are restored by hand with
# glue update-catalog). Not part of delete-stacks.sh: the role costs nothing.
#
# Environment:
#   REGION   (optional) - defaults to eu-west-1
#   PROFILE  (optional) - AWS CLI profile to use

set -euo pipefail

STACK="explore-kinesis-lake-formation"
REGION="${REGION:-eu-west-1}"
PROFILE="${PROFILE:-}"

AWS_FLAGS=(--region "${REGION}" --no-cli-pager)
if [[ -n "${PROFILE}" ]]; then
    AWS_FLAGS+=(--profile "${PROFILE}")
fi

log() {
    printf '\n>>> %s\n' "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Print the stack's status, or DOES_NOT_EXIST. Any other describe-stacks
# failure is printed to stderr and returns non-zero.
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

ACCOUNT_ID=$(aws sts get-caller-identity "${AWS_FLAGS[@]}" --query Account --output text)
RESOURCE_ARN="arn:aws:s3tables:${REGION}:${ACCOUNT_ID}:bucket/*"

log "Deregistering ${RESOURCE_ARN} from Lake Formation"

REGISTERED=$(aws lakeformation list-resources \
    "${AWS_FLAGS[@]}" \
    --query "length(ResourceInfoList[?ResourceArn=='${RESOURCE_ARN}'])" \
    --output text)

if [[ "${REGISTERED}" -gt 0 ]]; then
    aws lakeformation deregister-resource "${AWS_FLAGS[@]}" --resource-arn "${RESOURCE_ARN}"
    echo "    deregistered"
else
    echo "    not registered - nothing to do"
fi

log "Deleting ${STACK}"

STATUS=$(stack_status)
echo "    status: ${STATUS}"

case "${STATUS}" in
    DOES_NOT_EXIST|DELETE_COMPLETE)
        log "Stack does not exist - done."
        exit 0
        ;;
    DELETE_IN_PROGRESS) ;;
    *)
        aws cloudformation delete-stack "${AWS_FLAGS[@]}" --stack-name "${STACK}"
        ;;
esac

if aws cloudformation wait stack-delete-complete "${AWS_FLAGS[@]}" --stack-name "${STACK}"; then
    log "Stack deleted."
else
    aws cloudformation describe-stack-events \
        "${AWS_FLAGS[@]}" \
        --stack-name "${STACK}" \
        --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].[Timestamp,LogicalResourceId,ResourceStatusReason]" \
        --output table
    die "delete did not complete cleanly: $(stack_status)"
fi
