#!/usr/bin/env zsh
#
# Delete the explore-kinesis-app CloudFormation stack.
#
# Usage:
#   ./delete-app.sh                 # normal delete
#   ./delete-app.sh --retain <id>   # delete, retaining the named resource(s)
#                                   # repeat --retain for multiple resources
#
# Environment:
#   REGION   (optional) - defaults to eu-west-1
#   PROFILE  (optional) - AWS CLI profile to use

setopt err_exit nounset pipefail

# ---- Configuration ----------------------------------------------------------

STACK="explore-kinesis-app"
REGION="${REGION:-eu-west-1}"
PROFILE="${PROFILE:-}"

AWS_FLAGS=(--region "${REGION}")
if [[ -n "${PROFILE}" ]]; then
    AWS_FLAGS+=(--profile "${PROFILE}")
fi

# Collect --retain arguments into an array
retain_resources=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --retain)
            if [[ -z "${2:-}" ]]; then
                print -u2 "ERROR: --retain requires a logical resource ID"
                exit 1
            fi
            retain_resources+=("$2")
            shift 2
            ;;
        *)
            print -u2 "ERROR: unknown argument: $1"
            print -u2 "Usage: $0 [--retain <LogicalResourceId>]..."
            exit 1
            ;;
    esac
done

# ---- Helpers ----------------------------------------------------------------

log() {
    print "\n>>> $*"
}

stack_status() {
    aws cloudformation describe-stacks \
        "${AWS_FLAGS[@]}" \
        --stack-name "${STACK}" \
        --query "Stacks[0].StackStatus" \
        --output text 2>/dev/null \
        || print "DOES_NOT_EXIST"
}

# ---- Confirm credentials and stack existence --------------------------------

log "Resolving AWS account from active credentials"

account_id=$(aws sts get-caller-identity "${AWS_FLAGS[@]}" --query Account --output text)
print "    account: ${account_id}"
print "    region:  ${REGION}"
print "    stack:   ${STACK}"

log "Checking current stack status"

stack_state=$(stack_status)
print "    status: ${stack_state}"

case "${stack_state}" in
    DOES_NOT_EXIST)
        log "Stack does not exist - nothing to do."
        exit 0
        ;;
    DELETE_IN_PROGRESS)
        log "Stack delete already in progress - waiting for completion"
        ;;
    DELETE_COMPLETE)
        log "Stack already deleted."
        exit 0
        ;;
esac

# ---- Issue delete -----------------------------------------------------------

if [[ "${stack_state}" != "DELETE_IN_PROGRESS" ]]; then
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

print "\nMost recent failed events:"
aws cloudformation describe-stack-events \
    "${AWS_FLAGS[@]}" \
    --stack-name "${STACK}" \
    --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].[Timestamp,LogicalResourceId,ResourceStatusReason]" \
    --output table

print "\nTo skip a stuck resource, re-run with: --retain <LogicalResourceId>"
exit 1