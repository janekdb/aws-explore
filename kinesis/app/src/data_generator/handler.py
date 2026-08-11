import csv
import io
import logging
import os
import random
import string
from datetime import date, datetime, timedelta, timezone

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

s3 = boto3.client("s3")
BUCKET = os.environ["INPUTS_BUCKET"]

_START = date(1900, 1, 1)
_END = date(1999, 12, 31)
_DAY_SPAN = (_END - _START).days  # randint endpoints inclusive → covers full range


def _random_date() -> str:
    return (_START + timedelta(days=random.randint(0, _DAY_SPAN))).isoformat()


def _random_location() -> str:
    return "".join(random.choices(string.ascii_uppercase, k=3))


def main(event, context):
    rows = int(event.get("rows", 100))

    buf = io.StringIO()
    writer = csv.writer(buf, delimiter="\t", lineterminator="\n")
    writer.writerow(["date", "location", "temperature", "wind_speed"])
    for _ in range(rows):
        writer.writerow([
            _random_date(),
            _random_location(),
            f"{random.uniform(-100, 100):.1f}",
            f"{random.uniform(0, 50):.1f}",
        ])

    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
    key = f"weather-reports/{stamp}-{context.aws_request_id}.tsv"

    s3.put_object(
        Bucket=BUCKET,
        Key=key,
        Body=buf.getvalue().encode("utf-8"),
        ContentType="text/tab-separated-values",
    )

    log.info("wrote %d rows to s3://%s/%s", rows, BUCKET, key)
    return {"bucket": BUCKET, "key": key, "rows": rows}