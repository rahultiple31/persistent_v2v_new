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

SHORT_ABANDON_SECONDS = int(
    os.getenv("SHORT_ABANDON_SECONDS", "20")
)

OUTPUT_DELIMITER = os.getenv("OUTPUT_DELIMITER", ",")


# ============================================================
# AWS CLIENTS
# ============================================================

connect = boto3.client("connect")
s3 = boto3.client(
    "s3",
    region_name=os.environ["S3_REGION"]
)


# ============================================================
# CSV COLUMN ORDER
# ============================================================

COLUMNS = [
    "Root_Interaction_ID",
    "Service_Group",
    "Service",
    "Language",
    "Location",
    "ServiceCategory",
    "First Agent",
    "Last Agent",
    "Interaction type",
    "Start_D",
    "Start_T",
    "Start_H",
    "Offerred",
    "Handled",
    "Short Abandonded",
    "Abandoned",
    "Callback_Assist",
    "Callback_Assist_Time",
    "Q_VM",
    "NonQ_VM",
    "Speed of answer",
    "Talktime",
    "HoldCount",
    "Hold Time",
    "Handle time",
    "Wrapup time",
    "Consulting Time",
    "Country",
    "AbnCallTime",    
]


# ============================================================
# GENERAL HELPER FUNCTIONS
# ============================================================

def to_datetime(value):
    """
    Convert a supported timestamp value into a timezone-aware datetime.

    Supported inputs:
    - Python datetime
    - Epoch number
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
        try:
            parsed = datetime.fromisoformat(
                value.replace("Z", "+00:00")
            )

            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=timezone.utc)

            return parsed

        except ValueError:
            return None

    return None


def seconds_between(start_value, end_value):
    """
    Return the positive whole-second difference between timestamps.
    """

    start_datetime = to_datetime(start_value)
    end_datetime = to_datetime(end_value)

    if not start_datetime or not end_datetime:
        return 0

    difference = (
        end_datetime - start_datetime
    ).total_seconds()

    return max(0, int(round(difference)))


def safe_int(value, default=0):
    """
    Convert a value into an integer safely.
    """

    try:
        return int(round(float(value)))

    except (TypeError, ValueError):
        return default


def first_available(mapping, *keys, default=None):
    """
    Return the first existing, non-empty key from a dictionary.
    """

    if not mapping:
        return default

    for key in keys:
        if key in mapping:
            value = mapping[key]

            if value is not None and value != "":
                return value

    return default


def is_true(value):
    """
    Convert common truthy text values to Boolean.
    """

    return str(value).strip().lower() in {
        "1",
        "true",
        "yes",
        "y",
        "queued"
    }

def get_service_group(intent):
    """
    Derive Service_Group from the Intent contact attribute.

    Rules:
    - Intent starts with HR    -> HRDESK
    - Intent starts with Field -> FIELDSALES_HD
    - Intent starts with Veeva -> VEEVA_HD
    - Intent starts with Medcom -> MEDCOM_HD
    - All other values         -> SERVICEDESK

    Matching is case-insensitive and ignores leading/trailing spaces.
    """

    normalized_intent = str(intent or "").strip().upper()

    if normalized_intent.startswith("HR"):
        return "HRDESK"

    if normalized_intent.startswith("FIELD"):
        return "FIELDSALES_HD"

    if normalized_intent.startswith("VEEVA"):
        return "VEEVA_HD"

    if normalized_intent.startswith("MEDCOM"):
        return "MEDCOM_HD"

    return "SERVICEDESK"

# ============================================================
# AMAZON CONNECT API FUNCTIONS
# ============================================================

def search_contacts(start_utc, end_utc):
    """
    Search all contacts initiated within the supplied UTC range.

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
        response = connect.search_contacts(**request)

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
    Retrieve complete details for one contact.
    """

    response = connect.describe_contact(
        InstanceId=CONNECT_INSTANCE_ID,
        ContactId=contact_id
    )

    return response["Contact"]


def get_contact_attributes(contact):
    """
    Return user-defined contact attributes.

    DescribeContact normally provides attributes. If attributes are
    missing, GetContactAttributes is used as a fallback.
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

        return response.get("Attributes", {})

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
    Cache agent and queue names to reduce Amazon Connect API calls.
    """

    def __init__(self):
        self.user_cache = {}
        self.queue_cache = {}

    def get_user_name(self, user_id):
        """
        Resolve an Amazon Connect user ID to a display name.
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

            first_name = identity.get("FirstName", "")
            last_name = identity.get("LastName", "")

            display_name = " ".join(
                part
                for part in [first_name, last_name]
                if part
            ).strip()

            if not display_name:
                display_name = (
                    user.get("Username")
                    or user_id
                )

            self.user_cache[user_id] = display_name

        except Exception as error:
            logger.warning(
                "Could not resolve Amazon Connect user %s: %s",
                user_id,
                str(error)
            )

            self.user_cache[user_id] = user_id

        return self.user_cache[user_id]

    def get_queue_name(self, queue_id):
        """
        Resolve an Amazon Connect queue ID to a queue name.
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
                "Could not resolve Amazon Connect queue %s: %s",
                queue_id,
                str(error)
            )

            self.queue_cache[queue_id] = queue_id

        return self.queue_cache[queue_id]


# ============================================================
# METRIC CALCULATION FUNCTIONS
# ============================================================

def get_hold_time(contact):
    """
    Return agent-initiated hold time in seconds.
    """

    agent_info = contact.get("AgentInfo") or {}

    value = first_available(
        agent_info,
        "AgentInitiatedHoldDuration",
        "CustomerHoldDuration",
        "HoldDuration",
        default=0
    )

    return safe_int(value)


def get_hold_count(contact):
    """
    Return the number of hold occurrences.

    Amazon Connect does not expose hold count consistently in every
    API response. The function first checks possible native fields,
    then checks state transitions.
    """

    agent_info = contact.get("AgentInfo") or {}

    direct_count = first_available(
        agent_info,
        "AgentInitiatedHoldCount",
        "CustomerHoldCount",
        "HoldCount"
    )

    if direct_count is not None:
        return safe_int(direct_count)

    state_transitions = (
        agent_info.get("StateTransitions")
        or []
    )

    hold_count = 0

    for transition in state_transitions:
        state = str(
            transition.get("State", "")
        ).upper()

        if "HOLD" in state:
            hold_count += 1

    return hold_count


def get_wrapup_time(contact):
    """
    Return after-contact-work time in seconds.
    """

    agent_info = contact.get("AgentInfo") or {}

    direct_duration = first_available(
        agent_info,
        "AfterContactWorkDuration"
    )

    if direct_duration is not None:
        return safe_int(direct_duration)

    return seconds_between(
        agent_info.get(
            "AfterContactWorkStartTimestamp"
        ),
        agent_info.get(
            "AfterContactWorkEndTimestamp"
        )
    )


def get_talk_time(contact):
    """
    Return agent talk time in seconds.

    If a native agent interaction duration is available, it is used.
    Otherwise, talk time is derived from the connected timestamp up
    to ACW start or contact disconnection, minus hold time.
    """

    agent_info = contact.get("AgentInfo") or {}

    native_duration = first_available(
        agent_info,
        "AgentInteractionDuration",
        "TalkTime",
        "TalkDuration"
    )

    if native_duration is not None:
        return safe_int(native_duration)

    connected_timestamp = agent_info.get(
        "ConnectedToAgentTimestamp"
    )

    interaction_end_timestamp = (
        agent_info.get(
            "AfterContactWorkStartTimestamp"
        )
        or contact.get("DisconnectTimestamp")
    )

    connected_duration = seconds_between(
        connected_timestamp,
        interaction_end_timestamp
    )

    hold_duration = get_hold_time(contact)

    return max(
        0,
        connected_duration - hold_duration
    )


def get_consulting_time(contact, attributes):
    """
    Return consultation duration in seconds.

    The function first checks possible native fields. If unavailable,
    it uses a user-defined contact attribute.

    Supported attribute names:
    - ConsultingTime
    - Consulting_Time
    - ConsultDuration
    """

    agent_info = contact.get("AgentInfo") or {}

    native_duration = first_available(
        agent_info,
        "ConsultingTime",
        "ConsultDuration",
        "ConsultationDuration"
    )

    if native_duration is not None:
        return safe_int(native_duration)

    attribute_duration = first_available(
        attributes,
        "ConsultingTime",
        "Consulting_Time",
        "ConsultDuration",
        default=0
    )

    return safe_int(attribute_duration)


def is_queued_voicemail(attributes):
    """
    Q_VM is 1 when Attributes.voiceMailFrom is queueFlow.
    Otherwise Q_VM is 0.
    """

    voice_mail_from = str(
        attributes.get(
            "voiceMailFrom",
            ""
        )
    ).strip().lower()

    return (
        1
        if voice_mail_from == "queueflow"
        else 0
    )


def is_non_queued_voicemail(attributes):
    """
    NonQ_VM is 1 when Attributes.voiceMailFrom is surveyFlow.
    Otherwise NonQ_VM is 0.
    """

    voice_mail_from = str(
        attributes.get(
            "voiceMailFrom",
            ""
        )
    ).strip().lower()

    return (
        1
        if voice_mail_from == "surveyflow"
        else 0
    )


# ============================================================
# CONTACT GROUPING FUNCTIONS
# ============================================================

def contact_sort_timestamp(contact):
    """
    Return the timestamp used to sort contact segments.
    """

    return (
        to_datetime(contact.get("InitiationTimestamp"))
        or datetime.max.replace(tzinfo=timezone.utc)
    )

def get_root_interaction_id(contact):
    """
    Prefer the shared contact-tree root.
    Fall back to the initial contact ID, related contact ID,
    and finally the contact's own ID.
    """

    for field in (
        "ContactAssociationId",
        "InitialContactId",
        "RelatedContactId",
        "Id"
    ):
        value = contact.get(field)

        if value is not None and str(value).strip():
            return str(value).strip()

    return ""

def choose_primary_contact(segments):
    """
    Select the actual root contact when available.
    Otherwise use the earliest retrieved segment.
    """

    ordered_segments = sorted(
        segments,
        key=contact_sort_timestamp
    )

    if not ordered_segments:
        raise ValueError("No contact segments supplied.")

    root_ids = {
        get_root_interaction_id(segment)
        for segment in ordered_segments
    }

    for segment in ordered_segments:
        if segment.get("Id") in root_ids:
            return segment

    return ordered_segments[0]


def unique_agent_segments(segments):
    """
    Return chronologically ordered segments handled by agents.

    Consecutive duplicate segments for the same agent are retained for
    metric calculation but agent names are de-duplicated separately.
    """

    return [
        segment
        for segment in segments
        if (segment.get("AgentInfo") or {}).get("Id")
    ]


def ordered_unique_agent_ids(agent_segments):
    """
    Return agent IDs in handling order without consecutive duplicates.
    """

    agent_ids = []

    for segment in agent_segments:
        agent_id = (
            segment.get("AgentInfo") or {}
        ).get("Id")

        if not agent_id:
            continue

        if not agent_ids or agent_ids[-1] != agent_id:
            agent_ids.append(agent_id)

    return agent_ids


# ============================================================
# ROW GENERATION
# ============================================================

def build_csv_row(segments, resolver, business_timezone):
    """
    Consolidate related contact segments into one CSV interaction row.
    """

    segments = sorted(
        segments,
        key=contact_sort_timestamp
    )

    primary_contact = choose_primary_contact(
        segments
    )

    root_interaction_id = get_root_interaction_id(
        primary_contact
    )

    # Merge attributes from all related segments.
    # Later non-empty values override earlier values.
    attributes = {}

    for segment in segments:
        segment_attributes = get_contact_attributes(
            segment
        )

        for key, value in segment_attributes.items():
            if value is not None and str(value).strip() != "":
                attributes[key] = value

    # --------------------------------------------------------
    # AGENT PROCESSING
    # --------------------------------------------------------

    agent_segments = unique_agent_segments(
        segments
    )

    agent_ids = ordered_unique_agent_ids(
        agent_segments
    )

    first_agent = ""

    if agent_ids:
        first_agent = resolver.get_user_name(
            agent_ids[0]
        )

    last_agent = ""

    # Last Agent remains blank when only one unique agent handled
    # the entire interaction.
    if len(agent_ids) > 1:
        last_agent = resolver.get_user_name(
            agent_ids[-1]
        )

    # --------------------------------------------------------
    # QUEUE AND SERVICE PROCESSING
    # --------------------------------------------------------

    queue_segments = [
        segment
        for segment in segments
        if (segment.get("QueueInfo") or {}).get("Id")
    ]

    if queue_segments:
        service_segment = queue_segments[0]
    else:
        service_segment = primary_contact

    queue_info = (
        service_segment.get("QueueInfo")
        or {}
    )

    service = resolver.get_queue_name(
        queue_info.get("Id")
    )

    # --------------------------------------------------------
    # DATE AND TIME PROCESSING
    # --------------------------------------------------------

    start_utc = to_datetime(
        primary_contact.get("InitiationTimestamp")
    )

    if start_utc:
        start_local = start_utc.astimezone(
            business_timezone
        )
    else:
        start_local = None

    start_date = (
        start_local.strftime("%Y-%m-%d")
        if start_local
        else ""
    )

    # Requirement example:
    # If the interaction starts at 19:50:
    # Start_T = 19
    # Start_H = 19:50

    start_t = (
        start_local.strftime("%H")
        if start_local
        else ""
    )

    start_h = (
        start_local.strftime("%H:%M")
        if start_local
        else ""
    )

    # --------------------------------------------------------
    # OFFERED, HANDLED AND ABANDONED
    # --------------------------------------------------------

    offered = 1 if queue_segments else 0
    handled = 1 if agent_segments else 0

    abandoned = (
        1
        if offered == 1 and handled == 0
        else 0
    )

    abandoned_call_time = 0

    if abandoned and queue_segments:
        final_queue_segment = queue_segments[-1]

        final_queue_info = (
            final_queue_segment.get("QueueInfo")
            or {}
        )

        abandoned_call_time = seconds_between(
            final_queue_info.get("EnqueueTimestamp"),
            final_queue_segment.get(
                "DisconnectTimestamp"
            )
        )

    short_abandoned = (
        1
        if (
            abandoned == 1
            and abandoned_call_time
            <= SHORT_ABANDON_SECONDS
        )
        else 0
    )

    # --------------------------------------------------------
    # SPEED OF ANSWER
    # --------------------------------------------------------

    speed_of_answer = 0

    if agent_segments:
        first_handled_segment = agent_segments[0]

        first_agent_info = (
            first_handled_segment.get("AgentInfo")
            or {}
        )

        first_queue_info = (
            first_handled_segment.get("QueueInfo")
            or {}
        )

        enqueue_timestamp = first_queue_info.get(
            "EnqueueTimestamp"
        )

        connected_timestamp = first_agent_info.get(
            "ConnectedToAgentTimestamp"
        )

        speed_of_answer = seconds_between(
            enqueue_timestamp,
            connected_timestamp
        )

    # --------------------------------------------------------
    # AGENT METRICS
    # --------------------------------------------------------

    talk_time = sum(
        get_talk_time(segment)
        for segment in agent_segments
    )

    hold_time = sum(
        get_hold_time(segment)
        for segment in agent_segments
    )

    hold_count = sum(
        get_hold_count(segment)
        for segment in agent_segments
    )

    wrapup_time = sum(
        get_wrapup_time(segment)
        for segment in agent_segments
    )

    handle_time = (
        talk_time + wrapup_time
    )

    # Sum segment-native consultation durations.
    consulting_time = sum(
        get_consulting_time(segment, {})
        for segment in agent_segments
    )

    # Use the call-level attribute once if no native duration exists.
    if consulting_time == 0:
        consulting_time = safe_int(
            first_available(
                attributes,
                "ConsultingTime",
                "Consulting_Time",
                "ConsultDuration",
                default=0
            )
        )

    # --------------------------------------------------------
    # CALLBACK METRICS
    # --------------------------------------------------------

    initiation_method = str(
        primary_contact.get("InitiationMethod")
        or ""
    ).upper()

    # Flag the entire interaction if any segment is a callback.
    callback_assist = int(
        any(
            str(
                segment.get("InitiationMethod") or ""
            ).strip().upper() == "CALLBACK"
            for segment in segments
        )
    )

    callback_assist_time = (
        speed_of_answer
        if callback_assist == 1
        else 0
    )

    # --------------------------------------------------------
    # INTERACTION TYPE - ROOT CONTACT ONLY
    # --------------------------------------------------------

    root_contact = next(
        (
            segment
            for segment in segments
            if segment.get("Id") == root_interaction_id
        ),
        None
    )

    # Fetch the root contact if it is not in the retrieved segments.
    if root_contact is None:
        root_contact = describe_contact(
            root_interaction_id
        )

    interaction_type = str(
        root_contact.get("InitiationMethod") or ""
    ).strip().upper()

    logger.info(
        "ROOT_TYPE_SOURCE %s",
        json.dumps({
            "CSVRootInteractionId": root_interaction_id,
            "FetchedContactId": root_contact.get("Id"),
            "InitiationMethod": root_contact.get("InitiationMethod"),
            "InitialContactId": root_contact.get("InitialContactId"),
            "RelatedContactId": root_contact.get("RelatedContactId"),
            "ContactAssociationId": root_contact.get(
                "ContactAssociationId"
            ),
            "SegmentIds": [
                segment.get("Id")
                for segment in segments
            ]
        })
    )

    # --------------------------------------------------------
    # USER-DEFINED ATTRIBUTES
    # --------------------------------------------------------

    language = attributes.get(
        "Customer_Prefferred_Language",
        ""
    )

    location = attributes.get(
        "region",
        ""
    )

    service_category = attributes.get(
        "Intent",
        ""
    )

    service_group = get_service_group(
        service_category
    )   

    country = attributes.get(
        "country",
        ""
    )

    # --------------------------------------------------------
    # QUEUED VOICEMAIL - CHECK ALL RELATED SEGMENTS
    # --------------------------------------------------------

    q_vm = int(
        any(
            str(
                get_contact_attributes(segment).get(
                    "voiceMailFrom", ""
                ) or ""
            ).strip().lower() == "queueflow"
            for segment in segments
        )
    )

    # --------------------------------------------------------
    # NON-QUEUE VOICEMAIL - CHECK ALL RELATED SEGMENTS
    # --------------------------------------------------------

    non_q_vm = int(
        any(
            str(
                get_contact_attributes(segment).get(
                    "voiceMailFrom", ""
                ) or ""
            ).strip().lower() == "surveyflow"
            for segment in segments
        )
    )
    # --------------------------------------------------------
    # FINAL CSV ROW
    # --------------------------------------------------------

    return {
        "Root_Interaction_ID": root_interaction_id,
        "Service_Group": service_group,
        "Service": service,
        "First Agent": first_agent,
        "Last Agent": last_agent,
        "Interaction type": interaction_type,
        "Start_D": start_date,
        "Start_T": start_t,
        "Start_H": start_h,
        "Offerred": offered,
        "Handled": handled,
        "Short Abandonded": short_abandoned,
        "Abandoned": abandoned,
        "Callback_Assist": callback_assist,
        "Callback_Assist_Time": callback_assist_time,
        "Q_VM": q_vm,
        "NonQ_VM": non_q_vm,
        "Speed of answer": speed_of_answer,
        "Talktime": talk_time,
        "HoldCount": hold_count,
        "Hold Time": hold_time,
        "Handle time": handle_time,
        "Wrapup time": wrapup_time,
        "Consulting Time": consulting_time,
        "AbnCallTime": abandoned_call_time,
        "Language": language,
        "Location": location,
        "ServiceCategory": service_category,
        "Country": country,
    }


# ============================================================
# LAMBDA HANDLER
# ============================================================

def lambda_handler(event, context):
    """
    Main Lambda entry point.

    When the Lambda runs today, it exports contacts initiated during
    the previous calendar day in BUSINESS_TIMEZONE.
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
        "Starting Amazon Connect export."
    )

    logger.info(
        "Business timezone: %s",
        BUSINESS_TIMEZONE
    )

    logger.info(
        "Report date: %s",
        report_date.isoformat()
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
            contact = describe_contact(
                contact_id
            )

            detailed_contacts.append(
                contact
            )

        except Exception as error:
            logger.exception(
                "DescribeContact failed for contact %s",
                contact_id
            )

            describe_failures.append({
                "ContactId": contact_id,
                "Error": str(error)
            })

    logger.info(
        "Successfully described %s contacts.",
        len(detailed_contacts)
    )

    # --------------------------------------------------------
    # GROUP CONTACT SEGMENTS BY ROOT INTERACTION
    # --------------------------------------------------------
    # Log only identifiers needed to diagnose contact relationships.

    for contact in detailed_contacts:
        logger.info(
            "CONTACT_LINKS %s",
            json.dumps({
                "Id": contact.get("Id"),
                "InitiationMethod": contact.get("InitiationMethod"),
                "InitialContactId": contact.get("InitialContactId"),
                "PreviousContactId": contact.get("PreviousContactId"),
                "RelatedContactId": contact.get("RelatedContactId"),
                "ContactAssociationId": contact.get(
                    "ContactAssociationId"
                )
            })
        )

    interaction_groups = defaultdict(list)

    for contact in detailed_contacts:
        root_interaction_id = get_root_interaction_id(
            contact
        )

        if root_interaction_id:
            interaction_groups[
                root_interaction_id
            ].append(contact)

    logger.info(
        "Created %s root interaction groups.",
        len(interaction_groups)
    )

    # --------------------------------------------------------
    # GENERATE CSV ROWS
    # --------------------------------------------------------

    resolver = NameResolver()
    rows = []
    row_failures = []

    # One CSV row per root interaction.
    for root_interaction_id, segments in interaction_groups.items():
        try:
            # Deduplicate by Contact.Id to avoid counting a segment twice.
            unique_segments = {}

            for segment in segments:
                contact_id = segment.get("Id")

                if not contact_id:
                    raise ValueError(
                        "Contact segment is missing its Id."
                    )

                unique_segments[contact_id] = segment

            grouped_segments = sorted(
                unique_segments.values(),
                key=contact_sort_timestamp
            )

            logger.info(
                "Root interaction %s: passing %s segments together: %s",
                root_interaction_id,
                len(grouped_segments),
                [
                    segment.get("Id")
                    for segment in grouped_segments
                ]
            )

            # Pass ALL retrieved segments for this root together.
            row = build_csv_row(
                grouped_segments,
                resolver,
                business_timezone
            )

            # Use the same root ID used for grouping.
            row["Root_Interaction_ID"] = root_interaction_id

            # Exclude API-root interactions from the report.
            # Keep API segments grouped under an INBOUND root.
            if str(
                row.get("Interaction type") or ""
            ).strip().upper() == "API":
                logger.info(
                    "Excluding API-root interaction %s",
                    root_interaction_id
                )
                continue

            rows.append(row)

        except Exception as error:
            logger.exception(
                "Failed to build consolidated row for root %s",
                root_interaction_id
            )

            row_failures.append({
                "RootInteractionId": root_interaction_id,
                "Error": str(error)
            })

    # Do not upload a partial report.
    if describe_failures or row_failures:
        raise RuntimeError(
            "Export incomplete: "
            f"{len(describe_failures)} contact retrieval failures; "
            f"{len(row_failures)} row generation failures."
        )

    # Validate exactly one output row per retrieved root group.
    output_root_ids = [
        row["Root_Interaction_ID"]
        for row in rows
    ]

    if len(output_root_ids) != len(set(output_root_ids)):
        raise RuntimeError(
            "Validation failed: duplicate root interaction IDs "
            "found in the CSV output."
        )

    rows.sort(
        key=lambda row: (
            row.get("Start_D", ""),
            row.get("Start_H", ""),
            row.get("Root_Interaction_ID", "")
        )
    )

    # --------------------------------------------------------
    # CREATE CSV IN MEMORY
    # --------------------------------------------------------

    csv_buffer = io.StringIO(
        newline=""
    )

    writer = csv.DictWriter(
        csv_buffer,
        fieldnames=COLUMNS,
        delimiter=OUTPUT_DELIMITER,
        quoting=csv.QUOTE_MINIMAL,
        extrasaction="ignore"
    )

    writer.writeheader()
    writer.writerows(rows)

    # UTF-8 BOM helps Excel recognize the encoding correctly.
    csv_body = csv_buffer.getvalue().encode(
        "utf-8-sig"
    )

    # --------------------------------------------------------
    # CREATE S3 KEY
    # --------------------------------------------------------

    file_name = f"abbvieacd_{report_date:%Y-%m-%d}.csv"

    s3_key = f"{S3_PREFIX}/{file_name}"
    

    # --------------------------------------------------------
    # UPLOAD CSV TO S3
    # --------------------------------------------------------

    s3.put_object(
        Bucket=S3_BUCKET,
        Key=s3_key,
        Body=csv_body,
        ContentType="text/csv; charset=utf-8",
        Metadata={
            "business-timezone": BUSINESS_TIMEZONE,
            "report-date": report_date.isoformat(),
            "row-count": str(len(rows)),
            "source-contact-count": str(
                len(contact_summaries)
            )
        }
    )

    logger.info(
        "CSV successfully uploaded to s3://%s/%s",
        S3_BUCKET,
        s3_key
    )

    # --------------------------------------------------------
    # RESPONSE
    # --------------------------------------------------------

    result = {
        "statusCode": 200,
        "message": "Daily Amazon Connect CSV created successfully",
        "bucket": S3_BUCKET,
        "key": s3_key,
        "reportDate": report_date.isoformat(),
        "businessTimezone": BUSINESS_TIMEZONE,
        "sourceContacts": len(contact_summaries),
        "describedContacts": len(detailed_contacts),
        "rootInteractions": len(interaction_groups),
        "csvRows": len(rows),
        "describeFailureCount": len(describe_failures),
        "rowFailureCount": len(row_failures),
        "describeFailures": describe_failures,
        "rowFailures": row_failures
    }

    logger.info(
        json.dumps(
            result,
            default=str
        )
    )

    return result