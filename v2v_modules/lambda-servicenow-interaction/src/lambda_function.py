# Environment variables override the defaults below.
# Current V2V configuration sets SN_INSTANCE=abbvienowstage
# and SN_CTI_RULE=cti_gsd. Set SN_CTI_RULE=cti_gsd_aws in the
# Lambda environment to use the requested rule after deployment.

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
    "cti_gsd_aws"
).strip()

# Feature switch. Set SN_ENRICH_CALLER=false to instantly return to the
# previous behaviour (no extra caller parameters on the ScreenPopURL).
SN_ENRICH_CALLER = os.environ.get(
    "SN_ENRICH_CALLER",
    "true"
).strip().lower() not in ("false", "0", "no", "off")

URL_SCHEME = "https" + "://"
URL_DOMAIN = ".service-now" + ".com"
URL_PATH = "/cti.do"

UPI_PATTERN = re.compile(r"^[A-Za-z0-9-]+$")
UPI_MAX_LENGTH = 32

SYS_ID_LENGTH = 32
USER_ID_PATTERN = re.compile(r"^[A-Za-z0-9._@-]+$")
USER_ID_MAX_LENGTH = 100
PHONE_STRIP_PATTERN = re.compile(r"[\s().-]")
PHONE_MIN_DIGITS = 3
PHONE_MAX_DIGITS = 20

CONTACT_ID_PART_LENGTHS = [8, 4, 4, 4, 12]


def keys_from_env(env_name, default):
    # Attribute names can be overridden without a code change by
    # setting a comma separated environment variable.
    raw = os.environ.get(env_name, "").strip()

    if not raw:
        return default

    names = tuple(
        name.strip()
        for name in raw.split(",")
        if name.strip()
    )

    if names:
        return names

    return default


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

# sys_id of the caller found by the phone-number lookup (existing path).
PHONE_SYS_ID_KEYS = keys_from_env(
    "SN_PHONE_SYS_ID_ATTRS",
    (
        "CallerSysId",
        "caller_sys_id",
        "PhoneLookupSysId",
        "phone_lookup_sys_id"
    )
)

# sys_id of the caller found by the UPI lookup (fallback path).
UPI_SYS_ID_KEYS = keys_from_env(
    "SN_UPI_SYS_ID_ATTRS",
    (
        "UPISysId",
        "upi_sys_id",
        "UpiSysId",
        "UserSysId",
        "user_sys_id"
    )
)

# ServiceNow user_name / user id (for example TIPLERX) of the UPI user.
USER_ID_KEYS = keys_from_env(
    "SN_USER_ID_ATTRS",
    (
        "UserId",
        "user_id",
        "UserID",
        "UPIUserId",
        "upi_user_id"
    )
)

# Phone number of the caller (ANI) when passed explicitly.
PHONE_KEYS = keys_from_env(
    "SN_PHONE_ATTRS",
    (
        "CustomerNumber",
        "customer_number",
        "CallerPhone",
        "caller_phone"
    )
)

# Names of the extra query parameters sent to the ServiceNow CTI rule.
PARAM_CALLER_SYS_ID = "sysparm_caller_sys_id"
PARAM_CALLER_USER_ID = "sysparm_caller_user_id"
PARAM_CALLER_PHONE = "sysparm_caller_phone"

# Limits for the COMPLETE ScreenPopURL (both must be satisfied):
#   1. Maximum 3000 characters
#   2. Maximum 8 KB (8192 bytes, UTF-8)
MAX_URL_CHARS = 3000
MAX_URL_BYTES = 8 * 1024


def build_lookup(mapping):
    if not isinstance(mapping, dict):
        return dict()

    return dict(
        (str(k).lower(), v)
        for k, v in mapping.items()
    )


def lookup(lower_map, *keys):
    for key in keys:
        value = lower_map.get(key.lower())

        if value is not None:
            text = str(value).strip()

            if text:
                return text

    return ""


def get_param(parameters, *keys):
    return lookup(build_lookup(parameters), *keys)


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

        attr_map = build_lookup(attributes)

        parameters["_contact_id"] = contact_data.get(
            "ContactId",
            ""
        )

        parameters["_attribute_upi"] = lookup(
            attr_map,
            *UPI_KEYS
        )

        parameters["_attribute_description"] = lookup(
            attr_map,
            *DESCRIPTION_KEYS
        )

        # Caller identity attributes (used only to enrich the URL).
        parameters["_attribute_phone_sys_id"] = lookup(
            attr_map,
            *PHONE_SYS_ID_KEYS
        )

        parameters["_attribute_upi_sys_id"] = lookup(
            attr_map,
            *UPI_SYS_ID_KEYS
        )

        parameters["_attribute_user_id"] = lookup(
            attr_map,
            *USER_ID_KEYS
        )

        parameters["_attribute_phone"] = lookup(
            attr_map,
            *PHONE_KEYS
        )

        # ANI of the inbound call, when supplied by Amazon Connect.
        endpoint = contact_data.get("CustomerEndpoint")
        if isinstance(endpoint, dict):
            parameters["_ani"] = str(
                endpoint.get("Address") or ""
            ).strip()
        else:
            parameters["_ani"] = ""

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


def is_valid_sys_id(value):
    return (
        operator.eq(len(value), SYS_ID_LENGTH)
        and all(ch in string.hexdigits for ch in value)
    )


def is_valid_phone(value):
    # Optional single leading plus sign followed by ASCII digits only.
    digits = value[1:] if value.startswith("+") else value

    return (
        digits.isascii()
        and digits.isdigit()
        and operator.le(PHONE_MIN_DIGITS, len(digits))
        and operator.le(len(digits), PHONE_MAX_DIGITS)
    )


def first_value(parameters, keys, *extra_names):
    # Explicit flow parameters win over contact attributes.
    value = get_param(parameters, *keys)

    if value:
        return value

    return get_param(parameters, *extra_names)


def resolve_caller_identity(param_map):
    # Returns a tuple of (extra_query_params, caller_source).
    # Priority for the caller sys_id:
    #   1. phone-lookup caller (existing behaviour, unchanged)
    #   2. UPI-verified caller (new fallback)
    # Invalid optional values are dropped, never fatal: a screen pop
    # that opens as Guest is better than no screen pop at all.
    extra = []
    source = "none"

    sys_id = ""

    candidates = (
        ("phone_lookup", first_value(
            param_map, PHONE_SYS_ID_KEYS, "_attribute_phone_sys_id"
        )),
        ("upi_lookup", first_value(
            param_map, UPI_SYS_ID_KEYS, "_attribute_upi_sys_id"
        )),
    )

    for name, candidate in candidates:
        if not candidate:
            continue

        if is_valid_sys_id(candidate):
            sys_id = candidate.lower()
            source = name
            break

        logger.warning(
            "Ignoring invalid caller sys_id from %s.",
            name
        )

    if sys_id:
        extra.append((PARAM_CALLER_SYS_ID, sys_id))

    user_id = first_value(
        param_map, USER_ID_KEYS, "_attribute_user_id"
    )

    if user_id:
        if (
            operator.le(len(user_id), USER_ID_MAX_LENGTH)
            and USER_ID_PATTERN.fullmatch(user_id) is not None
        ):
            extra.append((PARAM_CALLER_USER_ID, user_id))
            if source == "none":
                source = "upi_user_id"
        else:
            logger.warning("Ignoring invalid caller user id.")

    phone = first_value(
        param_map, PHONE_KEYS, "_attribute_phone", "_ani"
    )

    if phone:
        phone = PHONE_STRIP_PATTERN.sub("", phone)

        if is_valid_phone(phone):
            extra.append((PARAM_CALLER_PHONE, phone))
        else:
            logger.warning("Ignoring invalid caller phone number.")

    return tuple(extra), source


def compose_url(upi, correlation_id, description="", extra_params=()):
    # Build a plain URL string, without HTML or Markdown.
    params = [
        ("sysparm_cti_rule", SN_CTI_RULE),
        ("sysparm_caller_id", upi),
        ("sysparm_correlation_id", correlation_id),
    ]

    # Identity parameters are placed BEFORE the description so they are
    # never lost when the description has to be shortened.
    params.extend(extra_params)

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
    description="",
    extra_params=()
):
    # The COMPLETE URL (after encoding) must be within 3000 chars
    # and 8 KB. Only the summary is shortened when needed.
    url = compose_url(upi, correlation_id, description, extra_params)

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
            description[:mid].rstrip(),
            extra_params
        )

        if url_within_limits(candidate):
            low = mid
        else:
            high = mid - 1

    description = description[:low].rstrip()
    url = compose_url(upi, correlation_id, description, extra_params)

    if not url_within_limits(url):
        # Only possible if UPI, ContactId, identity parameters and
        # instance alone exceed the limits.
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
    param_map = build_lookup(parameters)

    logger.info(
        "Screen-pop request received; source=%s",
        source
    )

    correlation_id = lookup(
        param_map,
        *CORRELATION_KEYS
    )

    if not correlation_id:
        correlation_id = lookup(
            param_map,
            "_contact_id"
        )

    upi = lookup(
        param_map,
        *UPI_KEYS
    )

    if not upi:
        upi = lookup(
            param_map,
            "_attribute_upi"
        )

    description = lookup(
        param_map,
        *DESCRIPTION_KEYS
    )

    if not description:
        description = lookup(
            param_map,
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

    extra_params = ()
    caller_source = "disabled"

    if SN_ENRICH_CALLER:
        extra_params, caller_source = resolve_caller_identity(
            parameters
        )

    try:
        screen_pop_url = build_screen_pop_url(
            upi,
            correlation_id,
            description,
            extra_params
        )
    except ValueError:
        return error_response(
            "UrlTooLong",
            "Unable to generate ScreenPopURL within URL limits."
        )

    logger.info(
        "ScreenPopURL generated successfully; caller_source=%s",
        caller_source
    )

    return success_response(
        upi,
        correlation_id,
        screen_pop_url
    )


handler = lambda_handler
