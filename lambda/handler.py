"""
Lambda entry point: triggered when a branch uploads an EOD file to the incoming bucket.

Flow:
  S3 (incoming, KMS-encrypted)  ->  this Lambda  ->  S3 (processed, KMS-encrypted)
      summary/<file>_summary.json
      compliance-review/<file>_review.csv   (only if high-value txns found)
      rejected/<file>_error.json            (if the file is malformed)
"""
import csv
import io
import json
import logging
import os
import urllib.parse

import boto3

from config import THRESHOLD_INR
from processor import FileRejected, evaluate_eod_file, format_inr

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
secrets = boto3.client("secretsmanager")

PROCESSED_BUCKET = os.environ["PROCESSED_BUCKET"]
SECRET_ARN = os.environ["COMPLIANCE_SECRET_ARN"]

_api_key = None  # cached across warm invocations


def _get_compliance_api_key():
    """Fetch the compliance-system API key from Secrets Manager (never hard-coded)."""
    global _api_key
    if _api_key is None:
        value = secrets.get_secret_value(SecretId=SECRET_ARN)["SecretString"]
        _api_key = json.loads(value)["api_key"]
        logger.info(
            "Fetched compliance API key from Secrets Manager (ending ****%s)",
            _api_key[-4:],
        )
    return _api_key


def _put_json(key, body):
    s3.put_object(
        Bucket=PROCESSED_BUCKET,
        Key=key,
        Body=json.dumps(body, indent=2).encode("utf-8"),
        ContentType="application/json",
    )


def lambda_handler(event, context):
    results = []
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        base = os.path.splitext(os.path.basename(key))[0]
        logger.info("Received EOD file s3://%s/%s", bucket, key)
        logger.info("Rule in force: review transactions >= %s", format_inr(THRESHOLD_INR))

        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf-8")

        try:
            summary, flagged = evaluate_eod_file(body, THRESHOLD_INR)
        except FileRejected as err:
            # Do not raise: S3 async invokes retry on error, which would duplicate work.
            logger.error("REJECTED %s: %s", key, err)
            _put_json(
                f"rejected/{base}_error.json",
                {"source_file": key, "status": "REJECTED", "reason": str(err)},
            )
            results.append({"file": key, "status": "REJECTED"})
            continue

        summary["source_file"] = key
        _put_json(f"summary/{base}_summary.json", summary)
        logger.info(
            "Processed %s: %d txns, %d flagged for compliance review",
            key, summary["txn_count"], summary["high_value_count"],
        )

        if flagged:
            out = io.StringIO()
            writer = csv.DictWriter(out, fieldnames=list(flagged[0].keys()))
            writer.writeheader()
            writer.writerows(flagged)
            s3.put_object(
                Bucket=PROCESSED_BUCKET,
                Key=f"compliance-review/{base}_review.csv",
                Body=out.getvalue().encode("utf-8"),
                ContentType="text/csv",
            )
            for f in flagged:
                logger.info(
                    "FLAGGED %s  %s  %s  %s",
                    f["txn_id"], f["account_no"], f["txn_type"], format_inr(f["amount_inr"]),
                )
            api_key = _get_compliance_api_key()
            logger.info(
                "[DEMO] Would raise %d case(s) in the compliance system using key ****%s",
                len(flagged), api_key[-4:],
            )

        results.append({"file": key, "status": "PROCESSED", "flagged": len(flagged)})

    return {"results": results}
