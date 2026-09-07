REGION=eu-west-1
aws cloudformation delete-stack --stack-name explore-kinesis-app --region $REGION
aws cloudformation wait stack-delete-complete --stack-name explore-kinesis-app --region $REGION

aws cloudformation delete-stack --stack-name explore-kinesis-database --region $REGION
aws cloudformation wait stack-delete-complete --stack-name explore-kinesis-database --region $REGION

aws cloudformation delete-stack --stack-name explore-kinesis-storage --region $REGION
aws cloudformation wait stack-delete-complete --stack-name explore-kinesis-storage --region $REGION
