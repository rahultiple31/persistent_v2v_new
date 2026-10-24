import logging
import operator
import os
import re
import string
import urllib.parse

# NOTE: This file intentionally avoids the characters less-than,
# greater-than, ampersand, curly braces and f-strings, so it survives
# copy/paste through chat windows and editors without being altered.

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SN_INSTANCE = os.environ.get(
    "SN_INSTANCE",
    "abbvienowdev"
).strip()

SN_CTI_RULE = os.environ.get(
    "SN_CTI_RULE",
    "cti_gsd"
).strip()

URL_SCHEME = "https" + "://"
URL_DOMAIN = ".service-now" + ".com"
URL_PATH = "/cti.do"

UPI_PATTERN = re.compile(r"^[A-Za-z0-9-]+$")
UPI_MAX_LENGTH = 32

CONTACT_ID_PART_LENGTHS = [8, 4, 4, 4, 12]

CORRELATION_KEYS = (
    "correlation_id",
    "CorrelationId",
    "ContactId",
    "contact_id",
    "contactId"
)

UPI_KEYS = (
    "UPI",
    "upi",
    "Upi"
)

DESCRIPTION_KEYS = (
    "CallSummary",
    "callSummary",
    "call_summary",
    "Description",
    "description"
)

# Limits for the COMPLETE ScreenPopURL (both must be satisfied):
#   1. Maximum 3000 characters
#   2. Maximum 8 KB (8192 bytes, UTF-8)
MAX_URL_CHARS = 3000
MAX_URL_BYTES = 8 * 1024


def get_param(parameters, *keys):
    if not isinstance(parameters, dict):
        return ""

    lower_map = dict(
        (str(k).lower(), v)
        for k, v in parameters.items()
    )

    for key in keys:
        value = lower_map.get(key.lower())

        if value is not None and str(value).strip():
            return str(value).strip()

    return ""


def extract_parameters(event):
    if not isinstance(event, dict):
        return dict(), "direct"

    # MCP Gateway format
    if isinstance(event.get("parameters"), dict):
        return dict(event["parameters"]), "mcp_gateway"

    # Amazon Connect Contact Flow
    if "Details" in event:
        details = event.get("Details")
        if not isinstance(details, dict):
            details = dict()

        flow_parameters = details.get("Parameters")
        if isinstance(flow_parameters, dict):
            parameters = dict(flow_parameters)
        else:
            parameters = dict()

        contact_data = details.get("ContactData")
        if not isinstance(contact_data, dict):
            contact_data = dict()

        attributes = contact_data.get("Attributes")
        if not isinstance(attributes, dict):
            attributes = dict()

        parameters["_contact_id"] = contact_data.get(
            "ContactId",
            ""
        )

        parameters["_attribute_upi"] = get_param(
            attributes,
            *UPI_KEYS
        )

        parameters["_attribute_description"] = get_param(
            attributes,
            *DESCRIPTION_KEYS
        )

        return parameters, "contact_flow"

    return dict(event), "direct"


def is_valid_upi(upi):
    return (
        operator.le(len(upi), UPI_MAX_LENGTH)
        and UPI_PATTERN.fullmatch(upi) is not None
    )


def is_valid_contact_id(contact_id):
    parts = contact_id.split("-")

    if [len(p) for p in parts] != CONTACT_ID_PART_LENGTHS:
        return False

    return all(
        ch in string.hexdigits
        for part in parts
        for ch in part
    )


def compose_url(upi, correlation_id, description=""):
    # Build a plain URL string, without HTML or Markdown.
    params = [
        ("sysparm_cti_rule", SN_CTI_RULE),
        ("sysparm_caller_id", upi),
        ("sysparm_correlation_id", correlation_id),
    ]

    if description:
        params.append(("sysparm_u_description", description))

    # quote_via=quote encodes spaces as %20 rather than +.
    query_string = urllib.parse.urlencode(
        params,
        quote_via=urllib.parse.quote,
        safe=""
    )

    return (
        URL_SCHEME
        + SN_INSTANCE
        + URL_DOMAIN
        + URL_PATH
        + "?"
        + query_string
    )


def url_within_limits(url):
    return (
        operator.le(len(url), MAX_URL_CHARS)
        and operator.le(len(url.encode("utf-8")), MAX_URL_BYTES)
    )


def build_screen_pop_url(
    upi,
    correlation_id,
    description=""
):
    # The COMPLETE URL (after encoding) must be within 3000 chars
    # and 8 KB. Only the summary is shortened when needed.
    url = compose_url(upi, correlation_id, description)

    if url_within_limits(url):
        return url

    original_len = len(description)

    # Find the longest summary prefix whose encoded URL fits.
    # The summary is cut BEFORE encoding, so a %XX sequence or a
    # multi-byte character is never split.
    low = 0
    high = original_len

    while operator.lt(low, high):
        mid = (low + high + 1) // 2

        candidate = compose_url(
            upi,
            correlation_id,
            description[:mid].rstrip()
        )

        if url_within_limits(candidate):
            low = mid
        else:
            high = mid - 1

    description = description[:low].rstrip()
    url = compose_url(upi, correlation_id, description)

    if not url_within_limits(url):
        # Only possible if UPI, ContactId and instance alone
        # exceed the limits.
        raise ValueError(
            "Unable to generate ScreenPopURL within URL limits."
        )

    logger.warning(
        "CallSummary shortened from %s to %s chars to keep "
        "ScreenPopURL within %s chars / %s bytes (final: %s chars).",
        original_len,
        len(description),
        MAX_URL_CHARS,
        MAX_URL_BYTES,
        len(url)
    )

    return url


def error_response(code, message):
    return dict(
        Status="Failure",
        Error=code,
        Message=message
    )


def success_response(
    upi,
    correlation_id,
    screen_pop_url
):
    return dict(
        Status="success",
        UPI=upi,
        CorrelationId=correlation_id,
        ScreenPopURL=screen_pop_url
    )


def lambda_handler(event, context):
    # Avoid logging the raw event or full URL because
    # they may contain employee information and call summaries.
    parameters, source = extract_parameters(event)

    logger.info(
        "Screen-pop request received; source=%s",
        source
    )

    correlation_id = get_param(
        parameters,
        *CORRELATION_KEYS
    )

    if not correlation_id:
        correlation_id = get_param(
            parameters,
            "_contact_id"
        )

    upi = get_param(
        parameters,
        *UPI_KEYS
    )

    if not upi:
        upi = get_param(
            parameters,
            "_attribute_upi"
        )

    description = get_param(
        parameters,
        *DESCRIPTION_KEYS
    )

    if not description:
        description = get_param(
            parameters,
            "_attribute_description"
        )

    if not correlation_id:
        return error_response(
            "MissingContactId",
            "ContactId is required."
        )

    if not upi:
        return error_response(
            "MissingUPI",
            "UPI is required."
        )

    if not is_valid_upi(upi):
        return error_response(
            "InvalidUPI",
            "Provided UPI failed format validation."
        )

    if not is_valid_contact_id(correlation_id):
        return error_response(
            "InvalidContactId",
            "ContactId must be a valid Amazon Connect ContactId UUID."
        )

    screen_pop_url = build_screen_pop_url(
        upi,
        correlation_id,
        description
    )

    logger.info("ScreenPopURL generated successfully.")

    return success_response(
        upi,
        correlation_id,
        screen_pop_url
    )


handler = lambda_handler
