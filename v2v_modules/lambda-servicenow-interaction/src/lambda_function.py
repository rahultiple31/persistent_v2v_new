import json
import logging
import os
import re
import urllib.parse

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

UPI_PATTERN = re.compile(
    r"^[A-Za-z0-9-]{1,32}$"
)

CONTACT_ID_PATTERN = re.compile(
    r"^[0-9a-fA-F]{8}-"
    r"[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{12}$"
)

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

# Summary field limits (both apply to the summary itself):
#   1. Maximum 3000 characters
#   2. Maximum 8 KB (8192 bytes, UTF-8)
MAX_SUMMARY_CHARS = 3000
MAX_SUMMARY_BYTES = 8 * 1024


def get_param(parameters, *keys):
    if not isinstance(parameters, dict):
        return ""

    lower_map = {
        str(k).lower(): v
        for k, v in parameters.items()
    }

    for key in keys:
        value = lower_map.get(key.lower())

        if value is not None and str(value).strip():
            return str(value).strip()

    return ""


def extract_parameters(event):
    if not isinstance(event, dict):
        return {}, "direct"

    # MCP Gateway format
    if isinstance(event.get("parameters"), dict):
        return dict(event["parameters"]), "mcp_gateway"

    # Amazon Connect Contact Flow
    if "Details" in event:
        details = event.get("Details")
        if not isinstance(details, dict):
            details = {}

        flow_parameters = details.get("Parameters")
        parameters = (
            dict(flow_parameters)
            if isinstance(flow_parameters, dict)
            else {}
        )

        contact_data = details.get("ContactData")
        if not isinstance(contact_data, dict):
            contact_data = {}

        attributes = contact_data.get("Attributes")
        if not isinstance(attributes, dict):
            attributes = {}

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


def limit_summary(summary):
    """
    Enforce both summary limits:
      - max 3000 characters
      - max 8 KB (8192 bytes in UTF-8)
    """
    if not summary:
        return ""

    original_chars = len(summary)
    original_bytes = len(summary.encode("utf-8"))

    # Limit 1: 3000 characters
    if len(summary) > MAX_SUMMARY_CHARS:
        summary = summary[:MAX_SUMMARY_CHARS]

    # Limit 2: 8 KB. Cut on bytes, then drop any partial character
    # at the cut point so multi-byte text (Hindi, accents) stays valid.
    encoded = summary.encode("utf-8")
    if len(encoded) > MAX_SUMMARY_BYTES:
        summary = encoded[:MAX_SUMMARY_BYTES].decode(
            "utf-8",
            errors="ignore"
        )

    summary = summary.rstrip()

    if len(summary) < original_chars:
        logger.warning(
            "Summary truncated. Original: %s chars / %s bytes. "
            "Final: %s chars / %s bytes. "
            "Limits: %s chars / %s bytes.",
            original_chars,
            original_bytes,
            len(summary),
            len(summary.encode("utf-8")),
            MAX_SUMMARY_CHARS,
            MAX_SUMMARY_BYTES
        )

    return summary


def build_screen_pop_url(
    upi,
    correlation_id,
    description=""
):
    # Build a plain URL string, without HTML or Markdown.
    params = {
        "sysparm_cti_rule": SN_CTI_RULE,
        "sysparm_caller_id": upi,
        "sysparm_correlation_id": correlation_id
    }

    if description:
        params["sysparm_u_description"] = description

    # quote_via=quote encodes spaces as %20 rather than +.
    query_string = urllib.parse.urlencode(
        params,
        quote_via=urllib.parse.quote,
        safe=""
    )

    return (
        f"https://{SN_INSTANCE}.service-now.com/cti.do?"
        f"{query_string}"
    )


def error_response(code, message):
    return {
        "Status": "Failure",
        "Error": code,
        "Message": message
    }


def success_response(
    upi,
    correlation_id,
    screen_pop_url
):
    return {
        "Status": "success",
        "UPI": upi,
        "CorrelationId": correlation_id,
        "ScreenPopURL": screen_pop_url
    }


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

    if not UPI_PATTERN.fullmatch(upi):
        return error_response(
            "InvalidUPI",
            "Provided UPI failed format validation."
        )

    if not CONTACT_ID_PATTERN.fullmatch(correlation_id):
        return error_response(
            "InvalidContactId",
            "ContactId must be a valid Amazon Connect ContactId UUID."
        )

    # Summary must not exceed 3000 chars or 8 KB.
    description = limit_summary(description)

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
