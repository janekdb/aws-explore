#!/usr/bin/env bash
#
# Delete the cost-generating explore-kinesis stacks, in dependency order.
# foundations and cfn-bootstrap are left in place.

set -euo pipefail

REGION="${REGION:-eu-west-1}"
POLL_SECONDS="${POLL_SECONDS:-10}"

# Order matters: each stack imports from those after it.
STACKS=(app firehose database storage)

stack_status() {
  aws cloudformation describe-stacks \
    --stack-name "$1" --region "$REGION" \
    --query 'Stacks[0].StackStatus' --output text \
    --no-cli-pager 2>/dev/null \
    || echo "DOES_NOT_EXIST"
}

log() {
  printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"
}

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
