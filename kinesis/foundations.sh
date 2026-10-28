#!/usr/bin/env bash
set -euo pipefail

aws cloudformation deploy \
  --template-file foundations.yaml \
  --stack-name explore-kinesis-foundations \
  --capabilities CAPABILITY_NAMED_IAM \
  --region eu-west-1 \
  --tags project=explore-kinesis \
  --no-fail-on-empty-changeset \
  # --no-execute-changeset
