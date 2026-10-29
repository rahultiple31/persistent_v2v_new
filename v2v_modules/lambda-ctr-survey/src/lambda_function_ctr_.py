import boto3
import csv
import io
import json
import logging
import os

from collections import defaultdict
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

LOG_LEVEL = os.getenv(
    "LOG_LEVEL",
    "INFO"
)


# ============================================================
# AWS CLIENTS
# ============================================================

connect = boto3.client("connect")
s3 = boto3.client(
    "s3",
    region_name=os.environ["S3_REGION"]
)


# ============================================================
# CSV COLUMNS
# ============================================================

CSV_COLUMNS = [
    "Syntellect_ID",
    "Call Start Time",
    "Survey Start Time",
    "Queue Name",
    "Survey Queue",
    "Region",
    "Survey Language",
    "SurveyInitFrom",
    "SurveyState",
    "First HD Agent Name",
    "Extension",
    "UPI",
    "Caller",
    "InboundCalls_Surveyed",
    "Surveys_Taken",
    "Surveys_Positive",
    "Surveys_Negative",
    "Survey_VM",
    "SurveyAnswer_01",
    "SurveyAnswer_02",
    "SurveyAnswer_03",
    "SurveyAnswer_04",
]


# ============================================================
# GENERAL HELPER FUNCTIONS
# ============================================================

def to_datetime(value):
    """
    Convert a supported timestamp into a timezone-aware datetime.

    Supported values:
    - datetime object
    - Unix epoch number
    - ISO-8601 string
    """

    if value is None or value == "":
        return None

    if isinstance(value, datetime):
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)

        return value

    if isinstance(value, (int, float, Decimal)):
        return datetime.fromtimestamp(
            float(value),
            tz=timezone.utc
        )

    if isinstance(value, str):
        value = value.strip()

        if not value:
            return None

        try:
            return datetime.fromisoformat(
                value.replace("Z", "+00:00")
            )

        except ValueError:
            pass

        # Optional support for common timestamp formats stored
        # in user-defined contact attributes.
        supported_formats = [
            "%Y-%m-%d %H:%M:%S",
            "%Y-%m-%d %H:%M",
            "%m/%d/%Y %H:%M:%S",
            "%m/%d/%Y %H:%M",
        ]

        for timestamp_format in supported_formats:
            try:
                parsed = datetime.strptime(
                    value,
                    timestamp_format
                )

                return parsed.replace(
                    tzinfo=timezone.utc
                )

            except ValueError:
                continue

    return None


def format_local_datetime(value, business_timezone):
    """
    Convert a timestamp into the business timezone and format it.

    Example:
    2026-10-07 19:50:25
    """

    timestamp = to_datetime(value)

    if not timestamp:
        return ""

    if timestamp.tzinfo is None:
        timestamp = timestamp.replace(
            tzinfo=timezone.utc
        )

    local_timestamp = timestamp.astimezone(
        business_timezone
    )

    return local_timestamp.strftime(
        "%Y-%m-%d %H:%M:%S"
    )


def first_available(mapping, keys, default=""):
    """
    Return the first non-empty value from a dictionary.
    """

    if not mapping:
        return default

    for key in keys:
        value = mapping.get(key)

        if value is not None and str(value).strip() != "":
            return value

    return default


def has_value(value):
    """
    Return True when the supplied value contains meaningful data.
    """

    return (
        value is not None
        and str(value).strip() != ""
    )


def normalized_text(value):
    """
    Return a trimmed uppercase string.
    """

    return str(value or "").strip().upper()


def contact_sort_timestamp(contact):
    """
    Return the timestamp used to sort contact segments.
    """

    return (
        to_datetime(
            contact.get("InitiationTimestamp")
        )
        or datetime.max.replace(
            tzinfo=timezone.utc
        )
    )
def get_survey_init_from(agent_c_value):
    """
    Derive SurveyInitFrom from Attributes.agentC.

    Rules:
    - true  -> Agent
    - false -> IVA
    - missing, blank or unrecognized -> blank
    """

    if isinstance(agent_c_value, bool):
        return "Agent" if agent_c_value else "IVA"

    normalized_value = str(
        agent_c_value or ""
    ).strip().lower()

    if normalized_value == "true":
        return "Agent"

    if normalized_value == "false":
        return "IVA"

    return ""

# ============================================================
# AMAZON CONNECT API FUNCTIONS
# ============================================================

def search_contacts(start_utc, end_utc):
    """
    Search contacts initiated during the supplied UTC time range.

    Pagination is handled automatically.
    """

    contacts = []

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

        contacts.extend(
            response.get("Contacts", [])
        )

        next_token = response.get("NextToken")

        if not next_token:
            break

        request["NextToken"] = next_token

    return contacts


def describe_contact(contact_id):
    """
    Retrieve detailed information for one contact.
    """

    response = connect.describe_contact(
        InstanceId=CONNECT_INSTANCE_ID,
        ContactId=contact_id
    )

    return response["Contact"]


def get_contact_attributes(contact):
    """
    Retrieve contact attributes.

    DescribeContact attributes are used first. If they are unavailable,
    GetContactAttributes is used as a fallback.
    """

    attributes = dict(
        contact.get("Attributes") or {}
    )

    if attributes:
        return attributes

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
            "Could not retrieve attributes for contact %s: %s",
            contact.get("Id"),
            str(error)
        )

        return {}


# ============================================================
# AGENT AND QUEUE NAME RESOLUTION
# ============================================================

class NameResolver:
    """
    Cache Amazon Connect agent and queue names.
    """

    def __init__(self):
        self.user_cache = {}
        self.queue_cache = {}

    def get_user_name(self, user_id):
        """
        Convert an Amazon Connect user ID into an agent name.
        """

        if not user_id:
            return ""

        if user_id in self.user_cache:
            return self.user_cache[user_id]

        try:
            response = connect.describe_user(
                InstanceId=CONNECT_INSTANCE_ID,
                UserId=user_id
            )

            user = response.get("User", {})
            identity = user.get("IdentityInfo") or {}

            first_name = str(
                identity.get("FirstName") or ""
            ).strip()

            last_name = str(
                identity.get("LastName") or ""
            ).strip()

            display_name = " ".join(
                value
                for value in [
                    first_name,
                    last_name
                ]
                if value
            )

            if not display_name:
                display_name = (
                    user.get("Username")
                    or user_id
                )

            self.user_cache[user_id] = display_name

        except Exception as error:
            logger.warning(
                "Could not resolve agent %s: %s",
                user_id,
                str(error)
            )

            self.user_cache[user_id] = user_id

        return self.user_cache[user_id]

    def get_queue_name(self, queue_id):
        """
        Convert an Amazon Connect queue ID into a queue name.
        """

        if not queue_id:
            return ""

        if queue_id in self.queue_cache:
            return self.queue_cache[queue_id]

        try:
            response = connect.describe_queue(
                InstanceId=CONNECT_INSTANCE_ID,
                QueueId=queue_id
            )

            queue = response.get("Queue", {})

            queue_name = (
                queue.get("Name")
                or queue_id
            )

            self.queue_cache[queue_id] = queue_name

        except Exception as error:
            logger.warning(
                "Could not resolve queue %s: %s",
                queue_id,
                str(error)
            )

            self.queue_cache[queue_id] = queue_id

        return self.queue_cache[queue_id]


# ============================================================
# CONTACT CHAIN AND ATTRIBUTE FUNCTIONS
# ============================================================

def choose_primary_contact(segments):
    """
    Select the initial/root contact segment.
    """

    ordered_segments = sorted(
        segments,
        key=contact_sort_timestamp
    )

    first_segment = ordered_segments[0]

    initial_contact_id = (
        first_segment.get("InitialContactId")
        or first_segment.get("Id")
    )

    for segment in ordered_segments:
        if segment.get("Id") == initial_contact_id:
            return segment

    return first_segment


def merge_attributes(segments):
    """
    Merge contact attributes from all segments.

    Later non-empty values override earlier values. This is useful when
    survey answers are written on a later survey contact segment.
    """

    merged = {}

    ordered_segments = sorted(
        segments,
        key=contact_sort_timestamp
    )

    for segment in ordered_segments:
        attributes = get_contact_attributes(
            segment
        )

        for key, value in attributes.items():
            if value is not None and str(value).strip() != "":
                merged[key] = value

    return merged


def segment_has_survey_data(segment, attributes):
    """
    Determine whether a segment appears to represent survey processing.

    A segment is considered survey-related when at least one of the
    following is true:

    - Journey contains the word Survey
    - SurveyQ1, SurveyQ2 or SurveyQ3 exists
    - SurveyIntent exists
    - A survey start timestamp attribute exists
    - Survey queue attribute exists
    """

    journey = normalized_text(
        attributes.get("journey", "")
    )

    if "SURVEY" in journey:
        return True

    survey_keys = [
        "SurveyQ1",
        "SurveyQ2",
        "SurveyQ3",
        "SurveyIntent",
        "surveyStartTime",
        "SurveyQueue",
        "SurveyQueueName",
    ]

    for key in survey_keys:
        if has_value(attributes.get(key)):
            return True

    contact_name = normalized_text(
        segment.get("Name", "")
    )

    contact_description = normalized_text(
        segment.get("Description", "")
    )

    if "SURVEY" in contact_name:
        return True

    if "SURVEY" in contact_description:
        return True

    return False


def identify_survey_segment(segments):
    """
    Return the first contact segment containing survey indicators.
    """

    ordered_segments = sorted(
        segments,
        key=contact_sort_timestamp
    )

    for segment in ordered_segments:
        attributes = get_contact_attributes(
            segment
        )

        if segment_has_survey_data(
            segment,
            attributes
        ):
            return segment, attributes

    return None, {}


def get_original_queue_segment(segments, survey_segment=None):
    """
    Return the first actual queued contact segment from the CTR chain.

    A queue segment is identified by the presence of QueueInfo.Id.
    Both Queue Name and Survey Queue will use this same segment.
    """

    ordered_segments = sorted(
        segments,
        key=contact_sort_timestamp
    )

    for segment in ordered_segments:
        queue_info = (
            segment.get("QueueInfo")
            or {}
        )

        if queue_info.get("Id"):
            return segment

    return None


def get_first_agent_segment(segments, survey_segment):
    """
    Return the first agent-handled segment before the survey step.
    """

    ordered_segments = sorted(
        segments,
        key=contact_sort_timestamp
    )

    for segment in ordered_segments:
        if (
            survey_segment
            and segment.get("Id") == survey_segment.get("Id")
        ):
            continue

        agent_info = (
            segment.get("AgentInfo")
            or {}
        )

        if agent_info.get("Id"):
            return segment

    return None


# ============================================================
# SURVEY TIMESTAMP AND QUEUE FUNCTIONS
# ============================================================

def get_survey_start_timestamp(
    survey_segment,
    survey_attributes,
    merged_attributes
):
    """
    Fetch Survey Start Time from Attributes.surveyStartTime.

    Check the survey segment attributes first, followed by the merged
    attributes from all related contact segments.

    Return None when the attribute is missing, blank, or invalid.
    """

    attribute_timestamp = first_available(
        survey_attributes,
        [
            "surveyStartTime"
        ],
        default=""
    )

    if not attribute_timestamp:
        attribute_timestamp = first_available(
            merged_attributes,
            [
                "surveyStartTime"
            ],
            default=""
        )

    if not attribute_timestamp:
        return None

    parsed_timestamp = to_datetime(
        attribute_timestamp
    )

    if not parsed_timestamp:
        logger.warning(
            "Unable to parse surveyStartTime value: %s",
            attribute_timestamp
        )

        return None

    return parsed_timestamp


def get_survey_queue_name(
    survey_segment,
    survey_attributes,
    merged_attributes,
    resolver
):
    """
    Determine the survey queue name.

    Priority:
    1. SurveyQueue attribute
    2. SurveyQueueName attribute
    3. survey_queue attribute
    4. QueueInfo.Id from the survey segment
    """

    survey_queue_attribute = first_available(
        survey_attributes,
        [
            "SurveyQueue",
            "SurveyQueueName",
            "survey_queue",
        ],
        default=""
    )

    if not survey_queue_attribute:
        survey_queue_attribute = first_available(
            merged_attributes,
            [
                "SurveyQueue",
                "SurveyQueueName",
                "survey_queue",
            ],
            default=""
        )

    if survey_queue_attribute:
        return str(
            survey_queue_attribute
        ).strip()

    if survey_segment:
        queue_info = (
            survey_segment.get("QueueInfo")
            or {}
        )

        queue_id = queue_info.get("Id")

        if queue_id:
            return resolver.get_queue_name(
                queue_id
            )

    return ""


# ============================================================
# SURVEY CLASSIFICATION FUNCTIONS
# ============================================================

def is_yes_or_no(value):
    """
    Return True if a survey answer is exactly Yes or No.
    """

    return normalized_text(value) in {
        "YES",
        "NO"
    }


def calculate_survey_metrics(
    survey_start_timestamp,
    survey_q1,
    survey_q2,
    survey_q3
):
    """
    Calculate survey status and survey indicators.

    SurveyState rules:

    Excluded:
        No survey start time.

    Abandoned:
        Survey started, but Q1, Q2 and Q3 are all blank.

    Taken:
        Q1, Q2 and Q3 all contain Yes or No.

    Partial:
        At least one answer is present, but the survey is not complete.

    Surveys_Taken:
        1 when at least one survey question was answered.
        0 when all three answers are blank.
    """

    inbound_calls_surveyed = (
        1
        if survey_start_timestamp
        else 0
    )

    answer_values = [
        survey_q1,
        survey_q2,
        survey_q3,
    ]

    answered_flags = [
        has_value(value)
        for value in answer_values
    ]

    answered_count = sum(
        1
        for answered in answered_flags
        if answered
    )

    all_answers_are_yes_or_no = all(
        is_yes_or_no(value)
        for value in answer_values
    )

    surveys_taken = (
        1
        if answered_count > 0
        else 0
    )

    if inbound_calls_surveyed == 0:
        survey_state = "Excluded"

    elif answered_count == 0:
        survey_state = "Abandoned"

    elif (
        answered_count == 3
        and all_answers_are_yes_or_no
    ):
        survey_state = "Taken"

    else:
        survey_state = "Partial"

    return {
        "InboundCalls_Surveyed": inbound_calls_surveyed,
        "Surveys_Taken": surveys_taken,
        "SurveyState": survey_state,
    }


def calculate_survey_vm(attributes):
    """
    Return Y when:

    - Attributes.journey contains the word Survey
    - Attributes.vmx3_transcript contains a value

    Otherwise return N.
    """

    journey = normalized_text(
        attributes.get("journey", "")
    )

    transcript = attributes.get(
        "vmx3_transcript",
        ""
    )

    if (
        "SURVEY" in journey
        and has_value(transcript)
    ):
        return "Y"

    return "N"


# ============================================================
# CSV ROW GENERATION
# ============================================================

def build_survey_row(
    segments,
    resolver,
    business_timezone
):
    """
    Consolidate a complete contact chain into one survey CSV row.
    """

    segments = sorted(
        segments,
        key=contact_sort_timestamp
    )

    primary_contact = choose_primary_contact(
        segments
    )

    merged_attributes = merge_attributes(
        segments
    )

    survey_segment, survey_segment_attributes = (
        identify_survey_segment(segments)
    )

    original_queue_segment = (
        get_original_queue_segment(
            segments,
            survey_segment
        )
    )

    first_agent_segment = (
        get_first_agent_segment(
            segments,
            survey_segment
        )
    )

    # --------------------------------------------------------
    # INTERACTION ID
    # --------------------------------------------------------

    syntellect_id = (
        primary_contact.get("InitialContactId")
        or primary_contact.get("Id", "")
    )

    # --------------------------------------------------------
    # CALL START TIME
    # --------------------------------------------------------

    call_start_timestamp = to_datetime(
        primary_contact.get("InitiationTimestamp")
    )

    call_start_time = format_local_datetime(
        call_start_timestamp,
        business_timezone
    )

    # --------------------------------------------------------
    # SURVEY START TIME
    # --------------------------------------------------------

    survey_start_timestamp = (
        get_survey_start_timestamp(
            survey_segment,
            survey_segment_attributes,
            merged_attributes
        )
    )

    survey_start_time = format_local_datetime(
        survey_start_timestamp,
        business_timezone
    )

    # --------------------------------------------------------
    # QUEUE NAME AND SURVEY QUEUE FROM CTR QUEUE SEGMENT
    # --------------------------------------------------------

    queue_name = ""
    survey_queue = ""

    if original_queue_segment:
        original_queue_info = (
            original_queue_segment.get("QueueInfo")
            or {}
        )

        original_queue_id = original_queue_info.get(
            "Id"
        )

        if original_queue_id:
            resolved_queue_name = (
                resolver.get_queue_name(
                    original_queue_id
                )
            )

            queue_name = resolved_queue_name
            survey_queue = resolved_queue_name


    # --------------------------------------------------------
    # FIRST HELP DESK AGENT
    # --------------------------------------------------------

    first_hd_agent_name = ""

    if first_agent_segment:
        first_agent_info = (
            first_agent_segment.get("AgentInfo")
            or {}
        )

        first_hd_agent_name = (
            resolver.get_user_name(
                first_agent_info.get("Id")
            )
        )

    # --------------------------------------------------------
    # USER-DEFINED ATTRIBUTES
    # --------------------------------------------------------

    region = str(
        merged_attributes.get(
            "region",
            ""
        )
    ).strip()

    survey_language = str(
        merged_attributes.get(
            "lang",
            ""
        )
    ).strip()

    upi = str(
        merged_attributes.get(
            "UPI",
            ""
        )
    ).strip()

    caller = str(
        merged_attributes.get(
            "Email",
            ""
        )
    ).strip()

    survey_q1 = str(
        merged_attributes.get(
            "SurveyQ1",
            ""
        )
    ).strip()

    survey_q2 = str(
        merged_attributes.get(
            "SurveyQ2",
            ""
        )
    ).strip()

    survey_q3 = str(
        merged_attributes.get(
            "SurveyQ3",
            ""
        )
    ).strip()

    survey_q4 = str(
        merged_attributes.get(
            "SurveyIntent",
            ""
        )
    ).strip()

    # --------------------------------------------------------
    # SURVEY INITIATION SOURCE
    # --------------------------------------------------------

    survey_init_from = get_survey_init_from(
        merged_attributes.get(
            "agentC"
        )
    )

    # --------------------------------------------------------
    # POSITIVE AND NEGATIVE SURVEY INDICATORS
    # --------------------------------------------------------

    normalized_survey_q3 = normalized_text(
        survey_q3
    )

    surveys_positive = (
        1
        if normalized_survey_q3 == "YES"
        else 0
    )

    surveys_negative = (
        1
        if normalized_survey_q3 == "NO"
        else 0
    )

    # --------------------------------------------------------
    # SURVEY STATUS
    # --------------------------------------------------------

    survey_metrics = calculate_survey_metrics(
        survey_start_timestamp,
        survey_q1,
        survey_q2,
        survey_q3
    )

    survey_vm = calculate_survey_vm(
        merged_attributes
    )

    # --------------------------------------------------------
    # FINAL CSV ROW
    # --------------------------------------------------------

    return {
        "Syntellect_ID": syntellect_id,
        "Call Start Time": call_start_time,
        "Survey Start Time": survey_start_time,
        "Queue Name": queue_name,
        "Survey Queue": survey_queue,
        "Region": region,
        "Survey Language": survey_language,
        "SurveyInitFrom": survey_init_from,
        "SurveyState": survey_metrics["SurveyState"],
        "First HD Agent Name": first_hd_agent_name,
        "Extension": "",
        "UPI": upi,
        "Caller": caller,
        "InboundCalls_Surveyed": survey_metrics[
            "InboundCalls_Surveyed"
        ],
        "Surveys_Taken": survey_metrics[
            "Surveys_Taken"
        ],
        "Surveys_Positive": surveys_positive,
        "Surveys_Negative": surveys_negative,
        "Survey_VM": survey_vm,
        "SurveyAnswer_01": survey_q1,
        "SurveyAnswer_02": survey_q2,
        "SurveyAnswer_03": survey_q3,
        "SurveyAnswer_04": survey_q4,
    }


# ============================================================
# LAMBDA HANDLER
# ============================================================

def lambda_handler(event, context):
    """
    Generate one daily survey CSV for yesterday's interactions.

    Example:

    If the Lambda runs on 2026-10-08, it generates:

    connect/daily-interactions/
    abbvieacd_survey_2026-10-07.csv
    """

    business_timezone = ZoneInfo(
        BUSINESS_TIMEZONE
    )

    current_local_datetime = datetime.now(
        business_timezone
    )

    report_date = (
        current_local_datetime.date()
        - timedelta(days=1)
    )

    start_local = datetime.combine(
        report_date,
        datetime.min.time(),
        tzinfo=business_timezone
    )

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
        "Starting daily survey export."
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
        "Search range: %s to %s",
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
    # DESCRIBE CONTACTS
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
    # GROUP BY INITIAL CONTACT ID
    # --------------------------------------------------------

    interaction_groups = defaultdict(list)

    for contact in detailed_contacts:
        root_contact_id = (
            contact.get("InitialContactId")
            or contact.get("Id")
        )

        if root_contact_id:
            interaction_groups[
                root_contact_id
            ].append(contact)

    logger.info(
        "Created %s interaction groups.",
        len(interaction_groups)
    )

    # --------------------------------------------------------
    # GENERATE CSV ROWS
    # --------------------------------------------------------

    resolver = NameResolver()
    csv_rows = []
    row_failures = []

    for root_contact_id, segments in interaction_groups.items():
        try:
            primary_contact = choose_primary_contact(
                segments
            )

            # Exclude interactions initiated through API.
            initiation_method = str(
                primary_contact.get("InitiationMethod") or ""
            ).strip().upper()

            if initiation_method == "API":
                logger.info(
                    "Skipping root contact %s: InitiationMethod is API",
                    root_contact_id
                )
                continue

            csv_row = build_survey_row(
                segments,
                resolver,
                business_timezone
            )

            # Preserve the existing Survey Start Time filter.
            if not str(
                csv_row.get("Survey Start Time") or ""
            ).strip():
                continue

            csv_rows.append(csv_row)

        except Exception as error:
            logger.exception(
                "Failed to create survey row for %s",
                root_contact_id
            )

            row_failures.append({
                "RootContactId": root_contact_id,
                "Error": str(error)
            })

    csv_rows.sort(
        key=lambda row: (
            row.get("Call Start Time", ""),
            row.get("Syntellect_ID", "")
        )
    )

    # --------------------------------------------------------
    # CREATE CSV
    # --------------------------------------------------------

    csv_buffer = io.StringIO(
        newline=""
    )

    csv_writer = csv.DictWriter(
        csv_buffer,
        fieldnames=CSV_COLUMNS,
        delimiter=",",
        quoting=csv.QUOTE_MINIMAL,
        extrasaction="ignore"
    )

    csv_writer.writeheader()
    csv_writer.writerows(
        csv_rows
    )

    csv_body = csv_buffer.getvalue().encode(
        "utf-8-sig"
    )

    # --------------------------------------------------------
    # CREATE S3 FILE NAME
    # --------------------------------------------------------

    file_name = (
        f"abbvieacd_survey_"
        f"{report_date:%Y-%m-%d}.csv"
    )

    s3_key = (
        f"{S3_PREFIX}/"
        f"{file_name}"
    )

    # --------------------------------------------------------
    # UPLOAD CSV TO S3
    # --------------------------------------------------------

    s3.put_object(
        Bucket=S3_BUCKET,
        Key=s3_key,
        Body=csv_body,
        ContentType="text/csv; charset=utf-8",
        Metadata={
            "report-date": report_date.isoformat(),
            "business-timezone": BUSINESS_TIMEZONE,
            "row-count": str(len(csv_rows)),
            "source-contact-count": str(
                len(contact_summaries)
            )
        }
    )

    logger.info(
        "Survey CSV uploaded to s3://%s/%s",
        S3_BUCKET,
        s3_key
    )

    # --------------------------------------------------------
    # RETURN RESULT
    # --------------------------------------------------------

    result = {
        "statusCode": 200,
        "message": (
            "Daily survey CSV created successfully"
        ),
        "bucket": S3_BUCKET,
        "key": s3_key,
        "reportDate": report_date.isoformat(),
        "businessTimezone": BUSINESS_TIMEZONE,
        "sourceContacts": len(contact_summaries),
        "describedContacts": len(detailed_contacts),
        "interactionGroups": len(interaction_groups),
        "csvRows": len(csv_rows),
        "describeFailureCount": len(
            describe_failures
        ),
        "rowFailureCount": len(
            row_failures
        ),
        "describeFailures": describe_failures,
        "rowFailures": row_failures,
    }

    logger.info(
        json.dumps(
            result,
            default=str
        )
    )

    return result