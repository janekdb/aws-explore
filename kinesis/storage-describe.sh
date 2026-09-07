REGION=eu-west-1

aws cloudformation describe-stack-events \
  --stack-name explore-kinesis-storage \
  --region "$REGION" \
  --query "StackEvents[?ResourceStatusReason!=null].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]" \
  --output table