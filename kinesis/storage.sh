#!/bin/bash
set -euo pipefail

REGION=eu-west-1

ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name explore-kinesis-cfn-bootstrap \
  --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`RoleArn`].OutputValue' \
  --output text)

echo ROLE_ARN: $ROLE_ARN

if [ -z "$ROLE_ARN" ] || [ "$ROLE_ARN" = "None" ]; then
  echo "Could not resolve exec role ARN from bootstrap stack" >&2
  exit 1
fi

get_stack_output() {
  # $1 = stack name, $2 = output key.
  # Prints the output value, or nothing if the stack or key is absent.
  aws cloudformation describe-stacks \
    --stack-name "$1" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" \
    --output text 2>/dev/null || return 0   # missing stack -> empty, safe under set -e
}

PUB_ARN=$(get_stack_output explore-kinesis-app PublisherFunctionArn)

aws cloudformation deploy \
  --template-file storage.yaml \
  --stack-name explore-kinesis-storage \
  --region "$REGION" \
  --role-arn "$ROLE_ARN" \
  --parameter-overrides PublisherFunctionArn="$PUB_ARN" \
  --tags project=explore-kinesis \
  --no-fail-on-empty-changeset