import boto3
import csv
import io
import json
import logging
import os

from datetime import datetime, timedelta, timezone
from decimal import Decimal
from zoneinfo import ZoneInfo


# ============================================================
# LOGGING
# ============================================================

logger = logging.getLogger()
logger.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())


# ============================================================
# ENVIRONMENT VARIABLES
# ============================================================

CONNECT_INSTANCE_ID = os.environ["CONNECT_INSTANCE_ID"]
S3_BUCKET = os.environ["S3_BUCKET"]

S3_PREFIX = os.getenv(
    "S3_PREFIX",
    "connect/daily-interactions"
).strip("/")

BUSINESS_TIMEZONE = os.getenv(
    "BUSINESS_TIMEZONE",
    "America/Chicago"
)

OUTPUT_FILE_NAME = os.getenv(
    "OUTPUT_FILE_NAME",
    "test.csv"
)


# ============================================================
# AWS CLIENTS
# ============================================================

connect = boto3.client("connect")
s3 = boto3.client("s3")


# ============================================================
# JSON AND CSV HELPERS
# ============================================================

def json_default(value):
    """
    Convert non-standard JSON objects into readable values.
    """

    if isinstance(value, datetime):
        return value.isoformat()

    if isinstance(value, Decimal):
        return float(value)

    return str(value)


def clean_scalar(value):
    """
    Convert a value into a CSV-readable scalar.
    """

    if value is None:
        return ""

    if isinstance(value, datetime):
        return value.isoformat()

    if isinstance(value, Decimal):
        return str(value)

    if isinstance(value, bool):
        return "true" if value else "false"

    return value


def flatten(value, prefix="", output=None):
    """
    Flatten nested dictionaries into readable dot-separated columns.

    Example:

    AgentInfo.Id
    AgentInfo.ConnectedToAgentTimestamp
    QueueInfo.Id
    QueueInfo.EnqueueTimestamp

    Lists remain JSON strings because separating list entries into
    independent columns could lose the original structure.
    """

    if output is None:
        output = {}

    if isinstance(value, dict):

        if not value and prefix:
            output[prefix] = ""

        for key, item in value.items():

            if prefix:
                child_prefix = f"{prefix}.{key}"
            else:
                child_prefix = str(key)

            flatten(
                item,
                child_prefix,
                output
            )

    elif isinstance(value, list):

        output[prefix] = json.dumps(
            value,
            default=json_default,
            ensure_ascii=False,
            separators=(",", ":")
        )

    else:

        output[prefix] = clean_scalar(
            value
        )

    return output


# ============================================================
# TEST DATE PROCESSING
# ============================================================

def parse_report_date(event):
    """
    Read the requested date from the Lambda event.

    Supported event keys:

    report_date
    date
    ReportDate

    Supported formats:

    YYYY-MM-DD
    YYYY/MM/DD
    MM/DD/YYYY
    """

    event = event or {}

    raw_date = (
        event.get("report_date")
        or event.get("date")
        or event.get("ReportDate")
    )

    if not raw_date:
        raise ValueError(
            "A report date is required. "
            'Use test event: {"report_date":"2026-10-07"}'
        )

    raw_date = str(raw_date).strip()

    supported_formats = [
        "%Y-%m-%d",
        "%Y/%m/%d",
        "%m/%d/%Y",
    ]

    for date_format in supported_formats:

        try:
            return datetime.strptime(
                raw_date,
                date_format
            ).date()

        except ValueError:
            continue

    raise ValueError(
        f"Unsupported report date '{raw_date}'. "
        "Use YYYY-MM-DD, for example 2026-10-07."
    )


# ============================================================
# AMAZON CONNECT API FUNCTIONS
# ============================================================

def search_contacts(start_utc, end_utc):
    """
    Search all contacts initiated during the requested date.

    Pagination is handled automatically.
    """

    contact_summaries = []

    request = {
        "InstanceId": CONNECT_INSTANCE_ID,
        "TimeRange": {
            "Type": "INITIATION_TIMESTAMP",
            "StartTime": start_utc,
            "EndTime": end_utc,
        },
        "SearchCriteria": {},
        "MaxResults": 100,
    }

    while True:

        response = connect.search_contacts(
            **request
        )

        contact_summaries.extend(
            response.get("Contacts", [])
        )

        next_token = response.get(
            "NextToken"
        )

        if not next_token:
            break

        request["NextToken"] = next_token

    return contact_summaries


def describe_contact(contact_id):
    """
    Retrieve all fields available through DescribeContact.
    """

    response = connect.describe_contact(
        InstanceId=CONNECT_INSTANCE_ID,
        ContactId=contact_id
    )

    return response["Contact"]


def fetch_attributes(contact):
    """
    Retrieve all available user-defined attributes.

    Attributes provided by DescribeContact are used first.

    If none are present, GetContactAttributes is called using the
    InitialContactId.
    """

    described_attributes = dict(
        contact.get("Attributes") or {}
    )

    if described_attributes:
        return described_attributes

    initial_contact_id = (
        contact.get("InitialContactId")
        or contact.get("Id")
    )

    if not initial_contact_id:
        return {}

    try:

        response = connect.get_contact_attributes(
            InstanceId=CONNECT_INSTANCE_ID,
            InitialContactId=initial_contact_id
        )

        return dict(
            response.get("Attributes") or {}
        )

    except Exception as error:

        logger.warning(
            "GetContactAttributes failed for %s: %s",
            initial_contact_id,
            str(error)
        )

        return {}


# ============================================================
# AGENT AND QUEUE RESOLUTION
# ============================================================

class Resolver:
    """
    Resolve Amazon Connect agent IDs and queue IDs.

    Results are cached to avoid calling DescribeUser or DescribeQueue
    repeatedly for the same ID.
    """

    def __init__(self):

        self.users = {}
        self.queues = {}

    def user(self, user_id):
        """
        Resolve an agent ID to a readable agent name.
        """

        if not user_id:
            return ""

        if user_id in self.users:
            return self.users[user_id]

        try:

            response = connect.describe_user(
                InstanceId=CONNECT_INSTANCE_ID,
                UserId=user_id
            )

            user = response.get(
                "User",
                {}
            )

            identity = (
                user.get("IdentityInfo")
                or {}
            )

            first_name = identity.get(
                "FirstName"
            )

            last_name = identity.get(
                "LastName"
            )

            display_name = " ".join(
                value
                for value in [
                    first_name,
                    last_name
                ]
                if value
            ).strip()

            if not display_name:
                display_name = (
                    user.get("Username")
                    or user_id
                )

            self.users[user_id] = display_name

        except Exception as error:

            logger.warning(
                "DescribeUser failed for %s: %s",
                user_id,
                str(error)
            )

            self.users[user_id] = user_id

        return self.users[user_id]

    def queue(self, queue_id):
        """
        Resolve a queue ID to a readable queue name.
        """

        if not queue_id:
            return ""

        if queue_id in self.queues:
            return self.queues[queue_id]

        try:

            response = connect.describe_queue(
                InstanceId=CONNECT_INSTANCE_ID,
                QueueId=queue_id
            )

            queue = response.get(
                "Queue",
                {}
            )

            queue_name = (
                queue.get("Name")
                or queue_id
            )

            self.queues[queue_id] = queue_name

        except Exception as error:

            logger.warning(
                "DescribeQueue failed for %s: %s",
                queue_id,
                str(error)
            )

            self.queues[queue_id] = queue_id

        return self.queues[queue_id]


# ============================================================
# CSV ROW CREATION
# ============================================================

def build_rows(contacts):
    """
    Produce one CSV row per Amazon Connect contact segment.

    Each row contains:

    1. Contact-chain cross-reference columns
    2. Flattened DescribeContact data
    3. Segment-level contact attributes
    4. Merged attributes from all related contact segments
    5. Resolved agent and queue names
    6. Complete raw JSON
    """

    resolver = Resolver()

    interaction_groups = {}

    # Group related contact segments by InitialContactId.
    for contact in contacts:

        root_interaction_id = (
            contact.get("InitialContactId")
            or contact.get("Id")
        )

        interaction_groups.setdefault(
            root_interaction_id,
            []
        ).append(contact)

    csv_rows = []

    for root_interaction_id, segments in interaction_groups.items():

        segments.sort(
            key=lambda contact: (
                contact.get("InitiationTimestamp")
                or datetime.max.replace(
                    tzinfo=timezone.utc
                )
            )
        )

        segment_attributes = {}
        merged_chain_attributes = {}

        # Retrieve and merge attributes from all related segments.
        for segment in segments:

            attributes = fetch_attributes(
                segment
            )

            segment_id = segment.get("Id")

            segment_attributes[
                segment_id
            ] = attributes

            for key, value in attributes.items():

                if (
                    value is not None
                    and str(value).strip() != ""
                ):
                    merged_chain_attributes[
                        key
                    ] = value

        # Generate one row for every segment.
        for sequence, contact in enumerate(
            segments,
            start=1
        ):

            agent_info = (
                contact.get("AgentInfo")
                or {}
            )

            queue_info = (
                contact.get("QueueInfo")
                or {}
            )

            row = {
                "Resolved.RootInteractionId":
                    root_interaction_id,

                "Resolved.ChainSegmentNumber":
                    sequence,

                "Resolved.ChainSegmentCount":
                    len(segments),

                "Resolved.AgentName":
                    resolver.user(
                        agent_info.get("Id")
                    ),

                "Resolved.QueueName":
                    resolver.queue(
                        queue_info.get("Id")
                    ),
            }

            # Flatten all fields returned by DescribeContact.
            flattened_contact = flatten(
                contact,
                "Contact"
            )

            row.update(
                flattened_contact
            )

            # Add this segment's attributes.
            attributes = segment_attributes.get(
                contact.get("Id"),
                {}
            )

            for key, value in attributes.items():

                row[
                    f"Attribute.{key}"
                ] = clean_scalar(value)

            # Add combined attributes from all related segments.
            for key, value in merged_chain_attributes.items():

                row[
                    f"ChainAttribute.{key}"
                ] = clean_scalar(value)

            # Preserve the full Contact object as JSON.
            row["RawContactJSON"] = json.dumps(
                contact,
                default=json_default,
                ensure_ascii=False,
                separators=(",", ":")
            )

            # Preserve the full segment attributes as JSON.
            row["RawAttributesJSON"] = json.dumps(
                attributes,
                default=json_default,
                ensure_ascii=False,
                separators=(",", ":")
            )

            csv_rows.append(row)

    csv_rows.sort(
        key=lambda row: (
            str(
                row.get(
                    "Contact.InitiationTimestamp",
                    ""
                )
            ),
            str(
                row.get(
                    "Contact.Id",
                    ""
                )
            ),
        )
    )

    return csv_rows


# ============================================================
# DYNAMIC CSV COLUMN CREATION
# ============================================================

def ordered_columns(rows):
    """
    Build the complete CSV column list dynamically.

    Frequently used fields are placed first. All remaining dynamically
    discovered fields and attributes are added alphabetically.
    """

    preferred_columns = [
        "Resolved.RootInteractionId",
        "Resolved.ChainSegmentNumber",
        "Resolved.ChainSegmentCount",
        "Contact.Id",
        "Contact.InitialContactId",
        "Contact.PreviousContactId",
        "Contact.Channel",
        "Contact.InitiationMethod",
        "Contact.InitiationTimestamp",
        "Contact.DisconnectTimestamp",
        "Resolved.QueueName",
        "Contact.QueueInfo.Id",
        "Contact.QueueInfo.EnqueueTimestamp",
        "Resolved.AgentName",
        "Contact.AgentInfo.Id",
        "Contact.AgentInfo.ConnectedToAgentTimestamp",
    ]

    all_columns = set()

    for row in rows:
        all_columns.update(
            row.keys()
        )

    first_columns = [
        column
        for column in preferred_columns
        if column in all_columns
    ]

    raw_columns = [
        column
        for column in [
            "RawContactJSON",
            "RawAttributesJSON"
        ]
        if column in all_columns
    ]

    excluded_columns = (
        set(first_columns)
        | set(raw_columns)
    )

    remaining_columns = sorted(
        all_columns
        - excluded_columns
    )

    return (
        first_columns
        + remaining_columns
        + raw_columns
    )


# ============================================================
# LAMBDA HANDLER
# ============================================================

def lambda_handler(event, context):
    """
    Create test.csv using the date passed in the Lambda test event.
    """

    report_date = parse_report_date(
        event
    )

    business_timezone = ZoneInfo(
        BUSINESS_TIMEZONE
    )

    # Beginning of requested Chicago calendar date.
    start_local = datetime.combine(
        report_date,
        datetime.min.time(),
        tzinfo=business_timezone
    )

    # Beginning of the following Chicago calendar date.
    end_local = (
        start_local
        + timedelta(days=1)
    )

    start_utc = start_local.astimezone(
        timezone.utc
    )

    end_utc = end_local.astimezone(
        timezone.utc
    )

    logger.info(
        "Starting raw contact export."
    )

    logger.info(
        "Report date: %s",
        report_date.isoformat()
    )

    logger.info(
        "Business timezone: %s",
        BUSINESS_TIMEZONE
    )

    logger.info(
        "UTC search range: %s to %s",
        start_utc.isoformat(),
        end_utc.isoformat()
    )

    # --------------------------------------------------------
    # SEARCH CONTACTS
    # --------------------------------------------------------

    contact_summaries = search_contacts(
        start_utc,
        end_utc
    )

    logger.info(
        "SearchContacts returned %s contacts.",
        len(contact_summaries)
    )

    # --------------------------------------------------------
    # DESCRIBE EACH CONTACT
    # --------------------------------------------------------

    detailed_contacts = []
    describe_failures = []

    for summary in contact_summaries:

        contact_id = summary.get("Id")

        if not contact_id:
            continue

        try:

            detailed_contact = describe_contact(
                contact_id
            )

            detailed_contacts.append(
                detailed_contact
            )

        except Exception as error:

            logger.exception(
                "DescribeContact failed for %s",
                contact_id
            )

            describe_failures.append({
                "ContactId": contact_id,
                "Error": str(error)
            })

    # --------------------------------------------------------
    # BUILD CSV ROWS
    # --------------------------------------------------------

    csv_rows = build_rows(
        detailed_contacts
    )

    # When data exists, columns are discovered dynamically.
    if csv_rows:

        csv_columns = ordered_columns(
            csv_rows
        )

    else:

        # Create a readable header-only CSV if no contacts exist.
        csv_columns = [
            "Resolved.RootInteractionId",
            "Resolved.ChainSegmentNumber",
            "Resolved.ChainSegmentCount",
            "Contact.Id",
            "Contact.InitialContactId",
            "Contact.PreviousContactId",
            "Contact.Channel",
            "Contact.InitiationMethod",
            "Contact.InitiationTimestamp",
            "Contact.DisconnectTimestamp",
            "Resolved.QueueName",
            "Resolved.AgentName",
            "RawContactJSON",
            "RawAttributesJSON",
        ]

    # --------------------------------------------------------
    # CREATE CSV
    # --------------------------------------------------------

    csv_buffer = io.StringIO(
        newline=""
    )

    csv_writer = csv.DictWriter(
        csv_buffer,
        fieldnames=csv_columns,
        extrasaction="ignore",
        quoting=csv.QUOTE_MINIMAL
    )

    csv_writer.writeheader()
    csv_writer.writerows(
        csv_rows
    )

    # UTF-8 BOM makes the CSV easier to open correctly in Excel.
    csv_body = csv_buffer.getvalue().encode(
        "utf-8-sig"
    )

    # --------------------------------------------------------
    # CREATE S3 KEY
    # --------------------------------------------------------

    if S3_PREFIX:

        s3_key = (
            f"{S3_PREFIX}/"
            f"{OUTPUT_FILE_NAME}"
        )

    else:

        s3_key = OUTPUT_FILE_NAME

    # --------------------------------------------------------
    # UPLOAD TO S3
    # --------------------------------------------------------

    s3.put_object(
        Bucket=S3_BUCKET,
        Key=s3_key,
        Body=csv_body,
        ContentType="text/csv; charset=utf-8",
        Metadata={
            "report-date":
                report_date.isoformat(),

            "business-timezone":
                BUSINESS_TIMEZONE,

            "contact-count":
                str(len(detailed_contacts)),

            "row-count":
                str(len(csv_rows)),
        }
    )

    logger.info(
        "CSV uploaded to s3://%s/%s",
        S3_BUCKET,
        s3_key
    )

    # --------------------------------------------------------
    # RETURN RESULT
    # --------------------------------------------------------

    result = {
        "statusCode": 200,
        "message": (
            "Raw contact CSV created successfully"
        ),
        "reportDate": report_date.isoformat(),
        "businessTimezone": BUSINESS_TIMEZONE,
        "utcStart": start_utc.isoformat(),
        "utcEnd": end_utc.isoformat(),
        "bucket": S3_BUCKET,
        "key": s3_key,
        "searchResults": len(contact_summaries),
        "describedContacts": len(detailed_contacts),
        "csvRows": len(csv_rows),
        "csvColumns": len(csv_columns),
        "describeFailureCount": len(
            describe_failures
        ),
        "describeFailures": describe_failures,
    }

    logger.info(
        json.dumps(
            result,
            default=json_default
        )
    )

    return result
