aws \
  cloudformation deploy --template-file \
  iam-bootstrap.yaml \
  --stack-name explore-kinesis-cfn-bootstrap \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides AppName=explore-kinesis
