This is a learning project.

# Instructions

Do not edit files. The learner wishes to type all suggested CFN content and code.

Exception: shell scripts (`*.sh`) may be edited by Claude directly.

# Project Layout

One CloudFormation stack per directory, deployed by the `.sh` beside its `.yaml`.
Stack names are `explore-kinesis-<name>`.

<TOP LEVEL> - foundations (permissions boundary), iam-bootstrap (CFN exec role), storage
              (buckets + Kinesis stream; should move into a storage directory), helper scripts
app         - Lambdas
database    - S3 Tables
firehose    - Firehose: stream -> Iceberg table (in progress)
