"""Consolidate fixed-name regional seven-day snapshots into two fixed outputs.

No Secrets Manager or IAM user keys. Uses the Lambda execution role.
All source snapshots must describe the requested seven-day window.
"""
import boto3
import csv
import io
import json
import logging
import os
import tempfile
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from botocore.config import Config
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())
s3 = boto3.client("s3", region_name=os.environ["S3_REGION"],
                  config=Config(retries={"mode": "standard", "total_max_attempts": 4}))
REPORT_BUCKET = os.environ["REPORT_BUCKET"]
ACD_SOURCE_PREFIX = os.getenv("ACD_SOURCE_PREFIX", "daily/acd/").strip("/")
SURVEY_SOURCE_PREFIX = os.getenv("SURVEY_SOURCE_PREFIX", "daily/survey/").strip("/")
OUTPUT_PREFIX = os.getenv("OUTPUT_PREFIX", "consolidated/").strip("/")
EXPECTED_REGIONS = [v.strip() for v in os.getenv(
    "EXPECTED_REGIONS", "region-1,region-2,region-3").split(",") if v.strip()]
BUSINESS_TIMEZONE = os.getenv("BUSINESS_TIMEZONE", "America/Chicago")
FAIL_IF_REGION_MISSING = os.getenv("FAIL_IF_REGION_MISSING", "true").lower() == "true"
ADD_SOURCE_COLUMNS = os.getenv("ADD_SOURCE_COLUMNS", "false").lower() == "true"
CSV_ENCODING = os.getenv("CSV_ENCODING", "utf-8-sig")
CSV_DELIMITER = os.getenv("CSV_DELIMITER", ",")
SSE_KMS_KEY_ID = os.getenv("SSE_KMS_KEY_ID", "").strip()
MAX_SOURCE_BYTES = int(os.getenv("MAX_SOURCE_BYTES", str(512 * 1024 * 1024)))


def get_rolling_window(event):
    """Seven complete business-calendar days, excluding the run date.

    as_of_date: optional run date (YYYY-MM-DD).
    scheduled_time: optional EventBridge Scheduler ISO timestamp.
    reportDate/report_date: optional inclusive END date for compatibility.
    Use at most one override. Empty event uses the current business date.
    """
    event = event or {}
    tz = ZoneInfo(BUSINESS_TIMEZONE)
    choices = [key for key in ("as_of_date", "scheduled_time", "reportDate", "report_date")
               if event.get(key)]
    if len(choices) > 1:
        raise ValueError("Supply only one date override.")
    if event.get("as_of_date"):
        run_date = datetime.strptime(str(event["as_of_date"]), "%Y-%m-%d").date()
    elif event.get("scheduled_time"):
        stamp = datetime.fromisoformat(str(event["scheduled_time"]).replace("Z", "+00:00"))
        if stamp.tzinfo is None:
            raise ValueError("scheduled_time must include a timezone.")
        run_date = stamp.astimezone(tz).date()
    elif event.get("reportDate") or event.get("report_date"):
        end_date = datetime.strptime(str(event.get("reportDate") or event.get("report_date")), "%Y-%m-%d").date()
        run_date = end_date + timedelta(days=1)
    else:
        run_date = datetime.now(tz).date()
    start_date = run_date - timedelta(days=7)
    end_date = run_date - timedelta(days=1)
    start_local = datetime.combine(start_date, datetime.min.time(), tzinfo=tz)
    end_local = datetime.combine(run_date, datetime.min.time(), tzinfo=tz)
    return run_date, start_date, end_date, start_local, end_local


def object_key(*parts):
    return "/".join(str(part).strip("/") for part in parts if str(part).strip("/"))


def check_time(context):
    if context is not None and context.get_remaining_time_in_millis() < 60000:
        raise RuntimeError("Insufficient execution time to safely continue consolidation.")


def snapshot_sources(report_type, prefix, filename, window, context):
    run_date, start_date, end_date, _, _ = window
    expected_metadata = {
        "window-start": start_date.isoformat(),
        "window-end": end_date.isoformat(),
        "window-end-exclusive": run_date.isoformat(),
        "business-timezone": BUSINESS_TIMEZONE,
        "lookback-days": "7"
    }
    snapshots, missing = [], []
    for region in EXPECTED_REGIONS:
        check_time(context)
        key = object_key(prefix, region, filename)
        try:
            head = s3.head_object(Bucket=REPORT_BUCKET, Key=key)
        except ClientError as error:
            if error.response["Error"]["Code"] in ("404", "NoSuchKey", "NotFound"):
                missing.append(region)
                continue
            # Never interpret AccessDenied as an absent file.
            raise
        metadata = head.get("Metadata", {})
        for name, expected in expected_metadata.items():
            if metadata.get(name) != expected:
                raise RuntimeError(
                    f"{report_type} {region}: stale or incompatible source {key}; "
                    f"metadata {name}={metadata.get(name)!r}, expected {expected!r}. "
                    "Run the updated regional exporter first."
                )
        try:
            count = int(metadata["row-count"])
        except (KeyError, TypeError, ValueError) as error:
            raise RuntimeError(f"Missing/invalid row-count metadata: {key}") from error
        if count < 0:
            raise RuntimeError(f"Negative row count: {key}")
        snapshots.append({"region": region, "key": key, "etag": head["ETag"],
                          "rows": count, "size": head["ContentLength"]})
    if missing:
        message = f"{report_type}: missing regional files: {missing}"
        if FAIL_IF_REGION_MISSING:
            raise RuntimeError(message)
        logger.warning("%s; partial regional output explicitly enabled.", message)
    if not snapshots:
        raise RuntimeError(f"{report_type}: no usable regional files found.")
    return snapshots, missing


def build_csv(report_type, snapshots, path, context):
    headers = None
    total_rows = 0
    counts = {}
    with open(path, "w", encoding=CSV_ENCODING, newline="") as output:
        writer = csv.writer(output, delimiter=CSV_DELIMITER, lineterminator="\r\n")
        for source in snapshots:
            check_time(context)
            # Read the exact observed object content, or fail if overwritten.
            response = s3.get_object(Bucket=REPORT_BUCKET, Key=source["key"],
                                     IfMatch=source["etag"])
            count = 0
            with io.TextIOWrapper(response["Body"], encoding=CSV_ENCODING, newline="") as stream:
                reader = csv.reader(stream, delimiter=CSV_DELIMITER, strict=True)
                current_headers = next(reader, None)
                if (not current_headers or any(not h.strip() for h in current_headers)
                        or len(current_headers) != len(set(current_headers))):
                    raise RuntimeError(f"Invalid/duplicate CSV headers: {source['key']}")
                if headers is None:
                    headers = current_headers
                    if ADD_SOURCE_COLUMNS and set(headers) & {"SourceRegion", "SourceFile"}:
                        raise RuntimeError("Source tracking columns already exist in input.")
                    writer.writerow(headers + (["SourceRegion", "SourceFile"] if ADD_SOURCE_COLUMNS else []))
                elif current_headers != headers:
                    raise RuntimeError(f"{report_type}: schema mismatch in {source['key']}")
                for row in reader:
                    if not row:
                        continue
                    if len(row) != len(headers):
                        raise RuntimeError(f"Invalid row width in {source['key']} near line {reader.line_num}")
                    writer.writerow(row + ([source["region"], source["key"]] if ADD_SOURCE_COLUMNS else []))
                    count += 1
                    if count % 10000 == 0:
                        check_time(context)
            if count != source["rows"]:
                raise RuntimeError(f"Row-count mismatch in {source['key']}: {count} vs {source['rows']}")
            counts[source["region"]] = count
            total_rows += count
    return {"dataRows": total_rows, "regionalRowCounts": counts,
            "outputSizeBytes": os.path.getsize(path)}


def lambda_handler(event, context):
    event = event or {}
    if (not EXPECTED_REGIONS or len(EXPECTED_REGIONS) != len(set(EXPECTED_REGIONS))
            or any("/" in region for region in EXPECTED_REGIONS)):
        raise ValueError("EXPECTED_REGIONS must contain unique S3 folder names.")
    if len(CSV_DELIMITER) != 1 or CSV_DELIMITER in ('"', "\r", "\n"):
        raise ValueError("CSV_DELIMITER must be one valid delimiter character.")
    requested_type = str(event.get("reportType", "ALL")).strip().upper()
    if requested_type not in ("ALL", "ACD", "SURVEY"):
        raise ValueError("reportType must be ALL, ACD or SURVEY.")
    window = get_rolling_window(event)
    run_date, start_date, end_date, _, _ = window
    definitions = [
        ("ACD", ACD_SOURCE_PREFIX, "btsgsd_abbvieacd.csv"),
        ("SURVEY", SURVEY_SOURCE_PREFIX, "btsgsd_abbvieacdsurvey.csv")
    ]
    plans = []
    for report_type, prefix, filename in definitions:
        if requested_type not in ("ALL", report_type):
            continue
        snapshots, missing = snapshot_sources(report_type, prefix, filename, window, context)
        output_key = object_key(OUTPUT_PREFIX, filename)
        if output_key in {item["key"] for item in snapshots}:
            raise ValueError("Consolidated output must not overwrite a regional source.")
        plans.append({"reportType": report_type, "filename": filename,
                      "outputKey": output_key, "sources": snapshots, "missingRegions": missing})
    if sum(source["size"] for plan in plans for source in plan["sources"]) > MAX_SOURCE_BYTES:
        raise RuntimeError("MAX_SOURCE_BYTES guardrail exceeded; review workload sizing.")
    csv.field_size_limit(10 * 1024 * 1024)
    with tempfile.TemporaryDirectory(prefix="rolling7-", dir="/tmp") as directory:
        # Validate and build every selected report before publishing either.
        for plan in plans:
            plan["localPath"] = os.path.join(directory, plan["filename"])
            plan.update(build_csv(plan["reportType"], plan["sources"], plan["localPath"], context))
        # Abort if any source changed during preparation.
        for plan in plans:
            for source in plan["sources"]:
                check_time(context)
                head = s3.head_object(Bucket=REPORT_BUCKET, Key=source["key"])
                if head["ETag"] != source["etag"]:
                    raise RuntimeError(f"Source changed during consolidation: {source['key']}; retry.")
        results = []
        for plan in plans:
            check_time(context)
            metadata = {
                "window-start": start_date.isoformat(), "window-end": end_date.isoformat(),
                "window-end-exclusive": run_date.isoformat(), "run-date": run_date.isoformat(),
                "business-timezone": BUSINESS_TIMEZONE, "lookback-days": "7",
                "report-type": plan["reportType"].lower(),
                "row-count": str(plan["dataRows"]),
                "source-file-count": str(len(plan["sources"])),
                "missing-regions": ",".join(plan["missingRegions"]),
                "generated-at-utc": datetime.now(timezone.utc).isoformat()
            }
            extra = {"ContentType": "text/csv; charset=utf-8", "Metadata": metadata}
            # Do not override bucket-default KMS encryption with AES256.
            if SSE_KMS_KEY_ID:
                extra.update(ServerSideEncryption="aws:kms", SSEKMSKeyId=SSE_KMS_KEY_ID)
            s3.upload_file(Filename=plan["localPath"], Bucket=REPORT_BUCKET,
                           Key=plan["outputKey"], ExtraArgs=extra)
            results.append({key: value for key, value in plan.items()
                            if key not in ("localPath", "sources", "filename")})
    response = {"statusCode": 200, "message": "Rolling seven-day regional consolidation completed.",
                "bucket": REPORT_BUCKET, "windowStart": start_date.isoformat(),
                "windowEnd": end_date.isoformat(), "windowEndExclusive": run_date.isoformat(),
                "businessTimezone": BUSINESS_TIMEZONE, "results": results}
    logger.info("ROLLING_CONSOLIDATION_COMPLETE %s", json.dumps(response))
    return response
