#!/usr/bin/env bash
set -euo pipefail

aws \
  cloudformation deploy --template-file \
  iam-bootstrap.yaml \
  --stack-name explore-kinesis-cfn-bootstrap \
  --capabilities CAPABILITY_NAMED_IAM \
  --region eu-west-1 \
  --parameter-overrides AppName=explore-kinesis \
  --no-fail-on-empty-changeset

# ---- Summary ----------------------------------------------------------------

printf '\n>>> %s\n' "Stack outputs"

aws cloudformation describe-stacks \
  --stack-name explore-kinesis-cfn-bootstrap \
  --region eu-west-1 \
  --query "Stacks[0].Outputs" \
  --output table \
  --no-cli-pager
