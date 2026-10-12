#!/usr/bin/env bash
#
# Delete the cost-generating explore-kinesis stacks, in dependency order.
# foundations and cfn-bootstrap are left in place.

set -euo pipefail

REGION="${REGION:-eu-west-1}"
POLL_SECONDS="${POLL_SECONDS:-10}"

# Order matters: each stack imports from those after it.
STACKS=(app firehose database storage)

# Print the stack's status, or DOES_NOT_EXIST. Any other describe-stacks
# failure (expired session, throttling, ...) is printed to stderr and
# returns non-zero, which aborts the script under set -e.
stack_status() {
  local err status
  err=$(mktemp)
  if status=$(aws cloudformation describe-stacks \
      --stack-name "$1" --region "$REGION" \
      --query 'Stacks[0].StackStatus' --output text \
      --no-cli-pager 2>"$err"); then
    rm -f "$err"
    echo "$status"
  elif grep -q 'does not exist' "$err"; then
    rm -f "$err"
    echo "DOES_NOT_EXIST"
  else
    cat "$err" >&2
    rm -f "$err"
    return 1
  fi
}

log() {
  printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"
}

# Empty a bucket owned by a stack so delete-stack does not end in
# DELETE_FAILED (BucketNotEmpty). Buckets are unversioned, so a recursive
# rm is enough. No-op if the resource or bucket no longer exists.
empty_stack_bucket() {
  local stack="$1" logical_id="$2" bucket
  bucket=$(aws cloudformation describe-stack-resource \
    --stack-name "$stack" --logical-resource-id "$logical_id" \
    --region "$REGION" --no-cli-pager \
    --query 'StackResourceDetail.PhysicalResourceId' --output text 2>/dev/null) \
    || return 0
  if [[ -z "$bucket" || "$bucket" == "None" ]]; then
    return 0
  fi
  if ! aws s3api head-bucket --bucket "$bucket" --region "$REGION" >/dev/null 2>&1; then
    log "$stack: bucket $bucket already gone - nothing to empty"
    return 0
  fi
  log "$stack: emptying s3://$bucket"
  aws s3 rm "s3://$bucket" --recursive --region "$REGION" --only-show-errors
}

# Fail fast on missing or expired credentials
aws sts get-caller-identity --region "$REGION" --no-cli-pager >/dev/null

for S in "${STACKS[@]}"; do
  STACK="explore-kinesis-$S"
  STATUS=$(stack_status "$STACK")

  case "$STATUS" in
    DOES_NOT_EXIST|DELETE_COMPLETE)
      log "$STACK: $STATUS - skipping"
      continue
      ;;
    DELETE_IN_PROGRESS)
      log "$STACK: delete already in progress - waiting"
      ;;
    *)
      log "$STACK: $STATUS - deleting"
      case "$S" in
        firehose) empty_stack_bucket "$STACK" ErrorBucket ;;
      esac
      aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION"
      ;;
  esac

  while :; do
    sleep "$POLL_SECONDS"
    STATUS=$(stack_status "$STACK")
    log "$STACK: $STATUS"
    case "$STATUS" in
      DELETE_IN_PROGRESS) ;;
      DOES_NOT_EXIST|DELETE_COMPLETE)
        break
        ;;
      DELETE_FAILED)
        log "$STACK: DELETE_FAILED - failed resources:"
        aws cloudformation describe-stack-events \
          --stack-name "$STACK" --region "$REGION" \
          --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].[LogicalResourceId,ResourceStatusReason]" \
          --output table --no-cli-pager
        exit 1
        ;;
      *)
        log "$STACK: unexpected status $STATUS - stopping"
        exit 1
        ;;
    esac
  done
done

log "All done."
