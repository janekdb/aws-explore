#!/usr/bin/env bash
#
# Invoke the data-generator Lambda once, synchronously, to push a test file
# through the pipeline:
#   generator -> inputs bucket (weather-reports/*.tsv) -> publisher -> Kinesis
#   -> Firehose -> weather.readings
#
# Usage:
#   ./invoke-generator.sh          # 100 rows (the handler's default)
#   ./invoke-generator.sh 5        # 5 rows
#
# Prints the handler's response (bucket, key, rows) and the tail of the
# invocation log. Exits non-zero if the function itself errored.
#
# Environment:
#   REGION   (optional) - defaults to eu-west-1
#   PROFILE  (optional) - AWS CLI profile to use

set -euo pipefail

REGION="${REGION:-eu-west-1}"
PROFILE="${PROFILE:-}"
FUNCTION="explore-kinesis-data-generator"
ROWS="${1:-100}"

[[ "${ROWS}" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: rows must be a positive integer, got '${ROWS}'" >&2; exit 1; }

AWS_FLAGS=(--region "${REGION}" --no-cli-pager)
if [[ -n "${PROFILE}" ]]; then
    AWS_FLAGS+=(--profile "${PROFILE}")
fi

log() {
    printf '\n>>> %s\n' "$*"
}

RESPONSE=$(mktemp)
trap 'rm -f "${RESPONSE}"' EXIT

log "Invoking ${FUNCTION} (rows=${ROWS})"

# --cli-binary-format: AWS CLI v2 otherwise expects the payload base64-encoded
META=$(aws lambda invoke \
    "${AWS_FLAGS[@]}" \
    --function-name "${FUNCTION}" \
    --cli-binary-format raw-in-base64-out \
    --payload "{\"rows\": ${ROWS}}" \
    --log-type Tail \
    --query '{error: FunctionError, log: LogResult}' \
    --output json \
    "${RESPONSE}")

log "Response"
cat "${RESPONSE}"
echo

log "Log tail"
jq -r '.log // empty' <<<"${META}" | base64 --decode

if [[ "$(jq -r '.error // empty' <<<"${META}")" != "" ]]; then
    echo "ERROR: ${FUNCTION} returned $(jq -r '.error' <<<"${META}")" >&2
    exit 1
fi

log "Done. Firehose buffers for up to 60s before rows reach weather.readings."
