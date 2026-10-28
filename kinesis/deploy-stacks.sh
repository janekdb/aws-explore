#!/usr/bin/env bash
#
# Deploy (or redeploy) every explore-kinesis stack, in dependency order, by
# running each stack's own deploy script. Counterpart to delete-stacks.sh.
#
# Idempotent: every step script uses --no-fail-on-empty-changeset, so an
# unchanged stack is a no-op and a full run is safe against a partly or
# fully deployed account.
#
# Steps (each imports from earlier ones):
#   foundations    permissions boundary                  (your credentials)
#   cfn-bootstrap  CFN exec role                         (your credentials)
#   storage-1      buckets + stream; no S3 -> Lambda notification yet,
#                  because the publisher does not exist
#   app            Lambdas (import inputs bucket + stream)
#   storage-2      storage.sh again: now finds PublisherFunctionArn and
#                  wires the inputs bucket to the publisher (HasPublisher)
#   database       S3 Tables bucket, namespace, table
#   firehose       stream -> Iceberg table, plus the LF grant
#
# Usage:
#   ./deploy-stacks.sh                  # all steps
#   ./deploy-stacks.sh --from app       # resume after a failed step
#   ./deploy-stacks.sh --to database    # stop early (e.g. leave out firehose)
#   ./deploy-stacks.sh --list           # print the step names
#
# Region is eu-west-1: several step scripts hard-code it.

set -euo pipefail

REGION=eu-west-1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parallel arrays (bash 3.2 has no associative arrays):
# step name | directory | script | stack it deploys
STEP_NAMES=( foundations      cfn-bootstrap    storage-1  app     storage-2  database     firehose     )
STEP_DIRS=(  .                .                .          app     .          database     firehose     )
STEP_SCRIPTS=(foundations.sh  iam-bootstrap.sh storage.sh app.sh  storage.sh database.sh  firehose.sh  )
STEP_STACKS=( foundations     cfn-bootstrap    storage    app     storage    database     firehose     )

# ---- Helpers ----------------------------------------------------------------

log() {
  printf '\n%s  === %s\n' "$(date +%H:%M:%S)" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

step_index() {
  local i
  for i in "${!STEP_NAMES[@]}"; do
    if [[ "${STEP_NAMES[$i]}" == "$1" ]]; then
      echo "$i"
      return 0
    fi
  done
  die "unknown step '$1' - one of: ${STEP_NAMES[*]}"
}

# Print the stack's status, or DOES_NOT_EXIST. Any other describe-stacks
# failure (expired session, throttling, ...) is printed and returns non-zero.
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

# Most recent failure reasons for a stack - the first thing to look at when
# a step fails. Best effort: silent if the stack is gone.
show_failures() {
  aws cloudformation describe-stack-events \
    --stack-name "$1" --region "$REGION" --no-cli-pager \
    --query "StackEvents[?ends_with(ResourceStatus, 'FAILED')] | [:8].[Timestamp,LogicalResourceId,ResourceStatusReason]" \
    --output table 2>/dev/null || true
}

# ---- Arguments --------------------------------------------------------------

FROM=0
TO=$(( ${#STEP_NAMES[@]} - 1 ))

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) [[ $# -ge 2 ]] || die "--from needs a step"; FROM=$(step_index "$2"); shift 2 ;;
    --to)   [[ $# -ge 2 ]] || die "--to needs a step";   TO=$(step_index "$2");   shift 2 ;;
    --list) printf '%s\n' "${STEP_NAMES[@]}"; exit 0 ;;
    -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) die "unknown argument '$1' (try --help)" ;;
  esac
done

(( FROM <= TO )) || die "--from ${STEP_NAMES[$FROM]} comes after --to ${STEP_NAMES[$TO]}"

# ---- Preflight --------------------------------------------------------------

log "Preflight"

# Fail fast on missing or expired credentials
aws sts get-caller-identity --region "$REGION" --no-cli-pager \
  --query '[Account,Arn]' --output text

command -v jq >/dev/null || die "jq is required (firehose.sh)"

# A stack in one of these states cannot be deployed over. Catch it now
# rather than part-way through. ROLLBACK_COMPLETE (failed first create)
# must be deleted first, e.g. with the stack's delete-*.sh.
# Database: recreating a table bucket soon after deleting it fails with a
# ConflictException while the name is still reserved - wait, then --from database.
for (( i = FROM; i <= TO; i++ )); do
  STACK="explore-kinesis-${STEP_STACKS[$i]}"
  STATUS=$(stack_status "$STACK")
  printf '    %-32s %s\n' "$STACK" "$STATUS"
  case "$STATUS" in
    *_IN_PROGRESS|*_FAILED|ROLLBACK_COMPLETE)
      die "$STACK is $STATUS - resolve that before deploying" ;;
  esac
done

# ---- Deploy -----------------------------------------------------------------

SECONDS=0

for (( i = FROM; i <= TO; i++ )); do
  NAME="${STEP_NAMES[$i]}"
  DIR="$ROOT/${STEP_DIRS[$i]}"
  SCRIPT="${STEP_SCRIPTS[$i]}"
  STACK="explore-kinesis-${STEP_STACKS[$i]}"
  STEP_START=$SECONDS

  log "[$(( i + 1 ))/${#STEP_NAMES[@]}] $NAME: ${STEP_DIRS[$i]}/$SCRIPT"

  # Run from the script's directory: some scripts use relative template paths.
  # Invoked via bash because not every script has a shebang / exec bit.
  if ! ( cd "$DIR" && bash "./$SCRIPT" ); then
    show_failures "$STACK"
    die "step '$NAME' failed. Fix it, then: ./deploy-stacks.sh --from $NAME"
  fi

  echo "    $NAME done in $(( SECONDS - STEP_START ))s"

  # storage.sh treats *any* failure to read the publisher ARN as "no app
  # stack" and would silently deploy without the notification. Check it.
  if [[ "$NAME" == "storage-2" ]]; then
    INPUTS_BUCKET=$(aws cloudformation describe-stacks \
      --stack-name "$STACK" --region "$REGION" --no-cli-pager \
      --query "Stacks[0].Outputs[?OutputKey=='InputsBucketName'].OutputValue" \
      --output text)
    N=$(aws s3api get-bucket-notification-configuration \
      --bucket "$INPUTS_BUCKET" --region "$REGION" --no-cli-pager \
      --query 'length(LambdaFunctionConfigurations || `[]`)' --output text)
    if [[ "$N" -lt 1 ]]; then
      die "s3://$INPUTS_BUCKET has no Lambda notification - publisher not wired"
    fi
    echo "    s3://$INPUTS_BUCKET -> publisher notification present"
  fi
done

# ---- Summary ----------------------------------------------------------------

log "Deployed ${STEP_NAMES[$FROM]} .. ${STEP_NAMES[$TO]} in $(( SECONDS / 60 ))m $(( SECONDS % 60 ))s"
bash "$ROOT/status.sh"
