REGION=eu-west-1
for S in foundations cfn-bootstrap storage app database; do
  printf '%-32s ' "explore-kinesis-$S"
  aws cloudformation describe-stacks \
    --stack-name "explore-kinesis-$S" --region "$REGION" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null \
    --no-cli-pager \
    || echo "NOT_DEPLOYED"
done