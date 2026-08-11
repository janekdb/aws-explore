import csv
import io
import json
import logging
import os
import urllib.parse

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

s3 = boto3.client("s3")
kinesis = boto3.client("kinesis")
STREAM = os.environ["STREAM_NAME"]

_BATCH_LIMIT = 500 # PutRecords max records per call


def _flush(batch):
    resp = kinesis.put_records(StreamName=STREAM, Records=batch)
    failed = resp.get("FailedRecordCount", 0)
    if failed:
        log.warning("PutRecords reported %d failed records", failed)
    return failed


def main(event, context):
    total = 0
    failed = 0

    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf-8")
        reader = csv.DictReader(io.StringIO(body), delimiter="\t")

        batch = []
        for row in reader:
            batch.append({
                "Data": (json.dumps(row) + "\n").encode("utf-8"),
                "PartitionKey": row["location"],
            })
            if len(batch) == _BATCH_LIMIT:
                failed += _flush(batch)
                total += len(batch)
                batch = []
        if batch:
            failed += _flush(batch)
            total += len(batch)

        log.info("Published %d records from s3://%s/%s", total, bucket, key)

    return {"published": total, "failed": failed}
