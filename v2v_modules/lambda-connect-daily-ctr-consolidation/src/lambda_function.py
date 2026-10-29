import boto3
import csv
import io
import json
import logging
import os
import re
import tempfile
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from typing import Dict, List, Optional

# Use the Lambda execution role for all S3 operations.
s3 = boto3.client(
    "s3",
    region_name=os.environ["S3_REGION"]
)

logger = logging.getLogger()
logger.setLevel(logging.INFO)


# ---------------------------------------------------------------------------
# Environment configuration
# ---------------------------------------------------------------------------

REPORT_BUCKET = os.environ["REPORT_BUCKET"]

ACD_SOURCE_PREFIX = os.environ.get(
    "ACD_SOURCE_PREFIX",
    "daily/acd/"
).strip("/")

SURVEY_SOURCE_PREFIX = os.environ.get(
    "SURVEY_SOURCE_PREFIX",
    "daily/survey/"
).strip("/")

OUTPUT_PREFIX = os.environ.get(
    "OUTPUT_PREFIX",
    "consolidated/"
).strip("/")

EXPECTED_REGIONS = [
    value.strip()
    for value in os.environ.get(
        "EXPECTED_REGIONS",
        "region-1,region-2,region-3"
    ).split(",")
    if value.strip()
]

BUSINESS_TIMEZONE = os.environ.get(
    "BUSINESS_TIMEZONE",
    "America/Chicago"
)

REPORT_DATE_OFFSET_DAYS = int(
    os.environ.get("REPORT_DATE_OFFSET_DAYS", "1")
)

FAIL_IF_REGION_MISSING = (
    os.environ.get(
        "FAIL_IF_REGION_MISSING",
        "false"
    ).lower() == "true"
)

ADD_SOURCE_COLUMNS = (
    os.environ.get(
        "ADD_SOURCE_COLUMNS",
        "true"
    ).lower() == "true"
)

CSV_ENCODING = os.environ.get(
    "CSV_ENCODING",
    "utf-8-sig"
)

SSE_KMS_KEY_ID = os.environ.get(
    "SSE_KMS_KEY_ID",
    ""
).strip()

# Supported date formats inside source S3 filenames.
DATE_PATTERNS = [
    # 2026-10-28
    re.compile(
        r"(?<!\d)(?P<year>\d{4})-(?P<month>\d{2})-(?P<day>\d{2})(?!\d)"
    ),

    # 20261028
    re.compile(
        r"(?<!\d)(?P<year>\d{4})(?P<month>\d{2})(?P<day>\d{2})(?!\d)"
    ),

    # 2026_10_28
    re.compile(
        r"(?<!\d)(?P<year>\d{4})_(?P<month>\d{2})_(?P<day>\d{2})(?!\d)"
    )
]


def normalize_prefix(prefix: str) -> str:
    """
    Remove leading/trailing slashes and add one trailing slash.
    """
    return prefix.strip("/") + "/"


def calculate_default_report_date() -> str:
    """
    Calculate the default reporting date in the configured business timezone.

    With REPORT_DATE_OFFSET_DAYS=1, a run on October 28 processes
    October 27 files.
    """
    timezone_value = ZoneInfo(BUSINESS_TIMEZONE)

    current_business_time = datetime.now(timezone_value)

    report_date = (
        current_business_time
        - timedelta(days=REPORT_DATE_OFFSET_DAYS)
    ).date()

    return report_date.isoformat()


def validate_report_date(report_date: str) -> str:
    """
    Validate and normalize the date as YYYY-MM-DD.
    """
    try:
        parsed_date = datetime.strptime(
            report_date,
            "%Y-%m-%d"
        ).date()
    except ValueError as error:
        raise ValueError(
            f"Invalid reportDate '{report_date}'. "
            f"Expected format is YYYY-MM-DD."
        ) from error

    return parsed_date.isoformat()


def extract_date_from_key(key: str) -> Optional[str]:
    """
    Extract the first supported date from an S3 key.

    Supported examples:
    ACD_2026-10-28.csv
    ACD_20261028.csv
    ACD_2026_10_28.csv
    """
    filename = key.rsplit("/", 1)[-1]

    for pattern in DATE_PATTERNS:
        match = pattern.search(filename)

        if not match:
            continue

        try:
            extracted_date = datetime(
                year=int(match.group("year")),
                month=int(match.group("month")),
                day=int(match.group("day"))
            ).date()

            return extracted_date.isoformat()

        except ValueError:
            continue

    return None


def identify_region(
    key: str,
    expected_regions: List[str]
) -> str:
    """
    Identify the source region from an exact S3 path segment.

    Example:
    daily/acd/us-east-1/abbvieacd_2026-10-28.csv
    """
    key_parts = key.split("/")

    for region in expected_regions:
        if region in key_parts:
            return region

    return "unknown"


def list_daily_csv_objects(
    bucket: str,
    prefix: str,
    report_date: str,
    report_type: str
) -> List[Dict]:
    """
    Find regional source files for the requested date.

    Missing regions are allowed.
    """

    normalized_prefix = normalize_prefix(prefix)

    if report_type == "ACD":
        expected_filename = (
            f"abbvieacd_{report_date}.csv"
        )
    elif report_type == "SURVEY":
        expected_filename = (
            f"abbvieacd_survey_{report_date}.csv"
        )
    else:
        raise ValueError(
            f"Unsupported report type: {report_type}"
        )

    paginator = s3.get_paginator(
        "list_objects_v2"
    )

    matching_objects = []

    for page in paginator.paginate(
        Bucket=bucket,
        Prefix=normalized_prefix
    ):
        for item in page.get("Contents", []):
            key = item["Key"]

            filename = key.rsplit("/", 1)[-1]

            if filename != expected_filename:
                continue

            matching_objects.append(
                {
                    "Key": key,
                    "Size": item.get("Size", 0),
                    "LastModified": item.get(
                        "LastModified"
                    ),
                    "ETag": item.get(
                        "ETag",
                        ""
                    )
                }
            )

    matching_objects.sort(
        key=lambda value: value["Key"]
    )

    return matching_objects


def validate_expected_regions(
    source_objects: List[Dict],
    expected_regions: List[str],
    report_type: str,
    report_date: str
) -> None:
    """
    Confirm that one or more matching files exist for every
    configured region.
    """
    if not expected_regions:
        logger.warning(
            "%s %s: no expected regions configured.",
            report_type,
            report_date
        )
        return

    found_regions = set()

    for source_object in source_objects:
        source_region = identify_region(
            source_object["Key"],
            expected_regions
        )

        if source_region != "unknown":
            found_regions.add(source_region)

    missing_regions = sorted(
        set(expected_regions) - found_regions
    )

    if missing_regions:
        message = (
            f"{report_type} {report_date}: source files are missing "
            f"for regions {missing_regions}. Files were found for "
            f"regions {sorted(found_regions)}."
        )

        if FAIL_IF_REGION_MISSING:
            raise RuntimeError(message)

        logger.warning(message)


def open_s3_csv(bucket: str, key: str):
    """
    Stream one CSV from S3 rather than loading the complete object
    into Lambda memory.
    """
    response = s3.get_object(
        Bucket=bucket,
        Key=key
    )

    return io.TextIOWrapper(
        response["Body"],
        encoding=CSV_ENCODING,
        newline=""
    )


def upload_consolidated_file(
    local_path: str,
    bucket: str,
    output_key: str,
    metadata: Dict[str, str]
) -> None:
    """
    Upload the daily consolidated file.
    """
    extra_args = {
        "ContentType": "text/csv",
        "Metadata": metadata,
        "ServerSideEncryption": "aws:kms"
    }

    if SSE_KMS_KEY_ID:
        extra_args["SSEKMSKeyId"] = SSE_KMS_KEY_ID

    s3.upload_file(
        Filename=local_path,
        Bucket=bucket,
        Key=output_key,
        ExtraArgs=extra_args
    )


def build_daily_consolidated_csv(
    report_type: str,
    source_prefix: str,
    report_date: str
) -> Dict:
    """
    Combine all regional source files for one report type and one day.
    """
    source_objects = list_daily_csv_objects(
        bucket=REPORT_BUCKET,
        prefix=source_prefix,
        report_date=report_date,
        report_type=report_type
    )

    if not source_objects:
        raise RuntimeError(
            f"{report_type} {report_date}: no matching source CSV "
            f"files were found under "
            f"s3://{REPORT_BUCKET}/{normalize_prefix(source_prefix)}"
        )

    validate_expected_regions(
        source_objects=source_objects,
        expected_regions=EXPECTED_REGIONS,
        report_type=report_type,
        report_date=report_date
    )

    if report_type == "ACD":
        output_filename = (
            f"abbvieacd_{report_date}.csv"
        )
    elif report_type == "SURVEY":
        output_filename = (
            f"abbvieacdsurvey_{report_date}.csv"
        )
    else:
        raise ValueError(
            f"Unsupported report type: {report_type}"
        )

    output_key = (
        f"{normalize_prefix(OUTPUT_PREFIX)}"
        f"{output_filename}"
    )

    logger.info(
        "%s %s: found %s matching source files",
        report_type,
        report_date,
        len(source_objects)
    )

    expected_headers: Optional[List[str]] = None
    total_data_rows = 0
    processed_files = 0
    header_only_files = 0

    temporary_file = tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="",
        suffix=".csv",
        delete=False,
        dir="/tmp"
    )

    temporary_path = temporary_file.name

    try:
        writer = csv.writer(
            temporary_file,
            quoting=csv.QUOTE_MINIMAL,
            lineterminator="\n"
        )

        for source_object in source_objects:
            source_key = source_object["Key"]

            source_region = identify_region(
                source_key,
                EXPECTED_REGIONS
            )

            logger.info(
                "%s %s: processing s3://%s/%s",
                report_type,
                report_date,
                REPORT_BUCKET,
                source_key
            )

            text_stream = None

            try:
                text_stream = open_s3_csv(
                    REPORT_BUCKET,
                    source_key
                )

                reader = csv.reader(text_stream)

                try:
                    headers = next(reader)
                except StopIteration:
                    raise RuntimeError(
                        f"{report_type} {report_date}: source file "
                        f"is completely empty: "
                        f"s3://{REPORT_BUCKET}/{source_key}"
                    )

                if headers:
                    headers[0] = headers[0].lstrip("\ufeff")

                if not headers or not any(
                    str(value).strip()
                    for value in headers
                ):
                    raise RuntimeError(
                        f"{report_type} {report_date}: source file "
                        f"has a blank CSV header: "
                        f"s3://{REPORT_BUCKET}/{source_key}"
                    )

                if expected_headers is None:
                    expected_headers = headers.copy()

                    output_headers = expected_headers.copy()

                    if ADD_SOURCE_COLUMNS:
                        output_headers.extend(
                            [
                                "SourceRegion",
                                "SourceFile"
                            ]
                        )

                    writer.writerow(output_headers)

                    logger.info(
                        "%s %s: established schema with %s columns",
                        report_type,
                        report_date,
                        len(expected_headers)
                    )

                elif headers != expected_headers:
                    raise RuntimeError(
                        f"{report_type} {report_date}: CSV schema "
                        f"mismatch in s3://{REPORT_BUCKET}/{source_key}. "
                        f"Expected headers: {expected_headers}. "
                        f"Actual headers: {headers}."
                    )

                rows_from_file = 0

                for csv_row_number, row in enumerate(
                    reader,
                    start=2
                ):
                    if not row or not any(
                        str(value).strip()
                        for value in row
                    ):
                        continue

                    if len(row) != len(expected_headers):
                        raise RuntimeError(
                            f"{report_type} {report_date}: column "
                            f"count mismatch in "
                            f"s3://{REPORT_BUCKET}/{source_key} at "
                            f"row {csv_row_number}. Expected "
                            f"{len(expected_headers)} columns but "
                            f"found {len(row)}."
                        )

                    if ADD_SOURCE_COLUMNS:
                        row.extend(
                            [
                                source_region,
                                source_key
                            ]
                        )

                    writer.writerow(row)

                    rows_from_file += 1
                    total_data_rows += 1

                if rows_from_file == 0:
                    header_only_files += 1

                    logger.info(
                        "%s %s: header-only file accepted: %s",
                        report_type,
                        report_date,
                        source_key
                    )

                processed_files += 1

                logger.info(
                    "%s %s: added %s rows from %s",
                    report_type,
                    report_date,
                    rows_from_file,
                    source_key
                )

            finally:
                if text_stream is not None:
                    text_stream.close()

        temporary_file.flush()
        temporary_file.close()

        if expected_headers is None:
            raise RuntimeError(
                f"{report_type} {report_date}: no usable CSV "
                f"header was found."
            )

        generated_at = datetime.now(
            timezone.utc
        ).isoformat()

        metadata = {
            "report-type": report_type.lower(),
            "report-date": report_date,
            "generated-at-utc": generated_at,
            "source-file-count": str(processed_files),
            "data-row-count": str(total_data_rows)
        }

        upload_consolidated_file(
            local_path=temporary_path,
            bucket=REPORT_BUCKET,
            output_key=output_key,
            metadata=metadata
        )

        result = {
            "reportType": report_type,
            "reportDate": report_date,
            "bucket": REPORT_BUCKET,
            "sourcePrefix": normalize_prefix(
                source_prefix
            ),
            "outputKey": output_key,
            "processedFiles": processed_files,
            "headerOnlyFiles": header_only_files,
            "dataRows": total_data_rows,
            "outputSizeBytes": os.path.getsize(
                temporary_path
            ),
            "generatedAtUtc": generated_at
        }

        logger.info(
            "DAILY_CONSOLIDATION_COMPLETE %s",
            json.dumps(
                result,
                default=str
            )
        )

        return result

    except Exception:
        try:
            temporary_file.close()
        except Exception:
            pass

        raise

    finally:
        try:
            if os.path.exists(temporary_path):
                os.remove(temporary_path)
        except Exception as cleanup_error:
            logger.warning(
                "Unable to delete temporary file %s: %s",
                temporary_path,
                cleanup_error
            )


def lambda_handler(event, context):
    """
    Supported events:

    Default previous-business-day processing:
    {}

    Process an explicit date:
    {
      "reportDate": "2026-10-27"
    }

    Process only ACD:
    {
      "reportDate": "2026-10-27",
      "reportType": "ACD"
    }

    Process only Survey:
    {
      "reportDate": "2026-10-27",
      "reportType": "SURVEY"
    }
    """
    event = event or {}

    logger.info(
        "Daily consolidation started. Event: %s",
        json.dumps(
            event,
            default=str
        )
    )

    requested_report_type = str(
        event.get(
            "reportType",
            "ALL"
        )
    ).upper()

    if requested_report_type not in {
        "ALL",
        "ACD",
        "SURVEY"
    }:
        raise ValueError(
            f"Invalid reportType "
            f"'{requested_report_type}'. "
            f"Valid values: ALL, ACD, SURVEY."
        )

    requested_report_date = event.get(
        "reportDate"
    )

    if requested_report_date:
        report_date = validate_report_date(
            str(requested_report_date)
        )
    else:
        report_date = calculate_default_report_date()

    logger.info(
        "Processing report date %s in business timezone %s",
        report_date,
        BUSINESS_TIMEZONE
    )

    results = []

    if requested_report_type in {
        "ALL",
        "ACD"
    }:
        results.append(
            build_daily_consolidated_csv(
                report_type="ACD",
                source_prefix=ACD_SOURCE_PREFIX,
                report_date=report_date
            )
        )

    if requested_report_type in {
        "ALL",
        "SURVEY"
    }:
        results.append(
            build_daily_consolidated_csv(
                report_type="SURVEY",
                source_prefix=SURVEY_SOURCE_PREFIX,
                report_date=report_date
            )
        )

    response = {
        "statusCode": 200,
        "message": (
            "Daily report consolidation completed successfully."
        ),
        "reportDate": report_date,
        "results": results
    }

    logger.info(
        "CONSOLIDATION_COMPLETE %s",
        json.dumps(
            response,
            default=str
        )
    )

    return response
