REGION=eu-west-1
aws cloudformation delete-stack --stack-name explore-kinesis-database --region $REGION
aws cloudformation wait stack-delete-complete --stack-name explore-kinesis-database --region eu-west-1
