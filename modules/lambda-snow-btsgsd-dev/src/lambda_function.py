"""
ServiceNow_UserLookUp - production build v10.1 (contact-flow phone lookup).
Verifies an Amazon Connect / AgentCore Gateway caller against ServiceNow
sys_user: phone/ANI first (whole-number match), UPI (employee_number) as the
fallback.

v10.1:
  * PhoneLookupStatus is returned on EVERY flat response (contact flow, MCP
    Gateway, Bedrock agent): Matched | NotMatched | UPIMatched | Error.
  * Contact-flow calls return a COMPACT flat map: only the keys the flow and the
    prompt use, every value a string, every key always present. The full sys_user
    record is no longer copied into contact attributes / flow logs.
  * Contact-flow calls run on a tight time budget (CF_DEADLINE_SECONDS) so the
    Lambda always answers before the flow's Invoke-Lambda timeout.
  * Gateway / bot responses are otherwise unchanged (full record + profile).
  * BUILD is logged at cold start and on every call, so CloudWatch shows which
    code version actually ran.
Handler: lambda_function.lambda_handler
"""
import base64
import http.client
import json
import logging
import os
import re
import ssl
import time
import urllib.parse
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

BUILD = "userlookup-v10.1"


def _flag(name, default="false"):
    return os.environ.get(name, default).strip().lower() == "true"


# --- Configuration -----------------------------------------------------------
# Defaults allow SnapStart initialization without environment overrides.
SN_INSTANCE = os.environ.get("SN_INSTANCE", "abbvienow")
SN_USER_TABLE = os.environ.get("SN_USER_TABLE", "sys_user")
SN_SECRET_NAME = os.environ.get("SN_SECRET_NAME", "servicenow/prod")
SN_SECRET_USERNAME_KEY = os.environ.get("SN_SECRET_USERNAME_KEY", "username")
SN_SECRET_PASSWORD_KEY = os.environ.get("SN_SECRET_PASSWORD_KEY", "password")
# Gateway / agent calls: Connect kills a Lambda at 8s: worst case 3s + 0.2s + 3s = 6.2s.
REQUEST_TIMEOUT = float(os.environ.get("SN_REQUEST_TIMEOUT", "3"))
MAX_RETRIES = int(os.environ.get("SN_MAX_RETRIES", "1"))
RETRY_BACKOFF_BASE = float(os.environ.get("SN_RETRY_BACKOFF_BASE", "0.2"))
# Contact-flow calls: the whole lookup must finish inside this budget (seconds).
# Keep it at least 1 s below the flow block's InvocationTimeLimitSeconds (5).
CF_DEADLINE_SECONDS = float(os.environ.get("CF_DEADLINE_SECONDS", "3.8"))
CF_REQUEST_TIMEOUT = float(os.environ.get("CF_REQUEST_TIMEOUT", "1.8"))
PHONE_CANDIDATE_LIMIT = int(os.environ.get("SN_PHONE_CANDIDATE_LIMIT", "50"))
PHONE_MIN_DIGITS = int(os.environ.get("SN_PHONE_MIN_DIGITS", "7"))
PHONE_LIKE_FALLBACK_DIGITS = int(os.environ.get("SN_PHONE_LIKE_FALLBACK_DIGITS", "8"))
NEW_HIRE_WINDOW_DAYS = int(os.environ.get("USER_STATUS_NEW_HIRE_WINDOW_DAYS", "15"))
AUTH_REQUIRED_FIELDS = [f.strip() for f in os.environ.get("AUTH_REQUIRED_FIELDS", "sys_id").split(",") if f.strip()]
REQUIRE_ACTIVE_USER = _flag("REQUIRE_ACTIVE_USER")        # keep false: Active is decided by the HR journey
REJECT_LOCKED_OUT_USER = _flag("REJECT_LOCKED_OUT_USER")
LOG_RAW_EVENT = _flag("LOG_RAW_EVENT")                    # off in prod - the event carries caller phone numbers
SN_UPI_FIELD = os.environ.get("SN_UPI_FIELD", "employee_number")
SN_USER_ID_FIELD = os.environ.get("SN_USER_ID_FIELD", "user_name")
SN_FIELD_FORCE_FIELD = os.environ.get("SN_FIELD_FORCE_FIELD", "u_field_force")
SN_START_DATE_FIELD = os.environ.get("SN_START_DATE_FIELD", "u_startdate")
SN_DATE_FORMATS = ("%Y-%m-%d", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S")

UPI_RE = re.compile(r"^[A-Za-z0-9\-]{1,32}$")
NON_DIGIT_RE = re.compile(r"\D")
PHONE_TERM_RE = re.compile(r"\+?\d+")

UPI_PARAM_KEYS = ("upi",)
EMPTY_TOKENS = {"", "null", "none", "undefined", "n/a", "na", "nil", "unknown"}
PHONE_PARAM_KEYS = ("caller_ani", "callerani", "caller_phone", "callerphone",
                    "phone", "phonenumber", "_customer_num")
ACTION_ALIASES = {
    "authorize": "authorize", "verify_user": "authorize", "check_registration": "authorize",
    "get_user_profile": "get_user_profile", "get_caller_details": "get_user_profile",
    "lookup_caller": "get_user_profile", "lookup_user": "get_user_profile",
}
FLAT_RESPONSE_TYPES = ("contact_flow", "mcp_gateway", "bedrock_agent")
# Fields blanked before the record leaves this Lambda (never returned).
SENSITIVE_FIELDS = ("user_password",)

# Exact key set returned to the contact flow (all strings, always present).
CF_PROFILE_KEYS = ("FirstName", "LastName", "UPI", "UserId", "Email",
                   "FieldForce", "Active", "UserStatus")
CF_KEYS = ("PhoneLookupStatus", "Status", "AuthResult", "RegisteredCaller",
           "Error", "Message") + CF_PROFILE_KEYS
# Errors that mean "no match" (normal) rather than "lookup failed".
NO_MATCH_ERRORS = ("UserNotRegistered", "MissingIdentifier")

# --- Module-scope clients (reused across warm invocations) -------------------
_HOST = f"{SN_INSTANCE}.service-now.com"
_TABLE_PATH = f"/api/now/table/{SN_USER_TABLE}"
_SSL_CTX = ssl.create_default_context()
_secrets = boto3.client("secretsmanager")
_conn = None
_auth_header = None

# Per-invocation time budget (set by the handler; None = gateway defaults).
_deadline = None
_req_timeout = REQUEST_TIMEOUT
_max_retries = MAX_RETRIES

# A keep-alive connection that the server closed while idle fails fast with
# one of these; it is reopened once without spending the normal retry.
_STALE_CONN_ERRORS = (ConnectionResetError, BrokenPipeError,
                      http.client.BadStatusLine, http.client.CannotSendRequest)


class SnowHTTPError(Exception):
    def __init__(self, code):
        super().__init__(f"ServiceNow HTTP {code}")
        self.code = code


class DeadlineExceeded(Exception):
    pass


def _set_budget(invocation_type):
    global _deadline, _req_timeout, _max_retries
    if invocation_type == "contact_flow":
        _deadline = time.monotonic() + CF_DEADLINE_SECONDS
        _req_timeout = CF_REQUEST_TIMEOUT
        _max_retries = 0          # the bot retries once itself if the flow returns Error
    else:
        _deadline = None
        _req_timeout = REQUEST_TIMEOUT
        _max_retries = MAX_RETRIES


def _remaining():
    return None if _deadline is None else _deadline - time.monotonic()


def _get_auth_header():
    global _auth_header
    if _auth_header is None:
        try:
            secret = json.loads(_secrets.get_secret_value(SecretId=SN_SECRET_NAME)["SecretString"])
            creds = f"{secret[SN_SECRET_USERNAME_KEY]}:{secret[SN_SECRET_PASSWORD_KEY]}"
        except (KeyError, ValueError) as e:
            raise RuntimeError("Malformed ServiceNow credentials secret") from e
        _auth_header = "Basic " + base64.b64encode(creds.encode("utf-8")).decode("ascii")
    return _auth_header


def _reset_auth():
    global _auth_header
    _auth_header = None


def _close_conn():
    global _conn
    if _conn is not None:
        try:
            _conn.close()
        except Exception:
            pass
    _conn = None


def _request_timeout():
    """Socket timeout for the next request, capped by the remaining budget."""
    rem = _remaining()
    if rem is None:
        return _req_timeout
    if rem < 0.3:
        raise DeadlineExceeded()
    return min(_req_timeout, rem)


def _snow_get(query):
    """GET the user table over a reused TLS connection, with bounded retries
    on network errors and 5xx. Returns the 'result' list."""
    global _conn
    path = f"{_TABLE_PATH}?{urllib.parse.urlencode(query)}"
    headers = {"Accept": "application/json", "Authorization": _get_auth_header()}
    attempt = 0
    stale_retry_available = True
    auth_refresh_available = True
    while True:
        timeout = _request_timeout()
        reused = _conn is not None
        if _conn is None:
            _conn = http.client.HTTPSConnection(_HOST, timeout=timeout, context=_SSL_CTX)
        else:
            _conn.timeout = timeout
            if _conn.sock is not None:
                _conn.sock.settimeout(timeout)
        try:
            _conn.request("GET", path, headers=headers)
            resp = _conn.getresponse()
            status, raw = resp.status, resp.read()
        except _STALE_CONN_ERRORS:
            _close_conn()
            if reused and stale_retry_available:
                stale_retry_available = False
                continue
            if attempt < _max_retries:
                attempt += 1
                time.sleep(RETRY_BACKOFF_BASE * attempt)
                continue
            raise
        except (http.client.HTTPException, OSError):
            _close_conn()
            if attempt < _max_retries:
                attempt += 1
                time.sleep(RETRY_BACKOFF_BASE * attempt)
                continue
            raise
        if status >= 500 and attempt < _max_retries:
            attempt += 1
            logger.warning("ServiceNow HTTP %s, retrying", status)
            time.sleep(RETRY_BACKOFF_BASE * attempt)
            continue
        if status == 401 and auth_refresh_available:
            # Cached credentials may predate a secret rotation: refetch once, then retry.
            auth_refresh_available = False
            logger.warning("ServiceNow HTTP 401, refreshing credentials once")
            _reset_auth()
            _close_conn()
            headers["Authorization"] = _get_auth_header()
            continue
        if status >= 400:
            raise SnowHTTPError(status)
        try:
            body = json.loads(raw) if raw else {}
        except ValueError as e:
            raise RuntimeError("Malformed JSON response from ServiceNow") from e
        if "result" not in body:
            err = (body.get("error") or {}).get("message", "Unknown ServiceNow error")
            raise RuntimeError(f"ServiceNow error: {err}")
        return body["result"]


def _query_users(sysparm_query, limit):
    return _snow_get({
        "sysparm_query": sysparm_query,
        "sysparm_limit": str(limit),
        "sysparm_no_count": "true",
    })


# --- Helpers -------------------------------------------------------------------
def get_param(params, *keys):
    """First non-empty value for any of `keys`, matched case-insensitively."""
    if not params:
        return ""
    lower_map = {str(k).lower(): v for k, v in params.items()}
    for key in keys:
        val = lower_map.get(key.lower())
        if val and str(val).strip().lower() not in EMPTY_TOKENS:
            return str(val).strip()
    return ""


def _extract_value(val):
    """Normalise a sys_user field (plain value or {'value': ...} reference) to a string."""
    if isinstance(val, dict):
        return str(val.get("value") or "").strip()
    return "" if val is None else str(val).strip()


def _digits(value):
    return NON_DIGIT_RE.sub("", _extract_value(value))


def _strip_trunk_zero(digits):
    return digits[1:] if len(digits) > 1 and digits.startswith("0") else digits


# --- Phone / UPI lookup --------------------------------------------------------
def _phones_match(stored, target_digits):
    """Whole-number match: the full shorter number must equal the tail of the
    longer one (absorbs +, country codes and a national trunk '0')."""
    stored_digits = _digits(stored)
    if not stored_digits or not target_digits:
        return False
    for s in {stored_digits, _strip_trunk_zero(stored_digits)}:
        for t in {target_digits, _strip_trunk_zero(target_digits)}:
            longer, shorter = (s, t) if len(s) >= len(t) else (t, s)
            if len(shorter) >= PHONE_MIN_DIGITS and longer.endswith(shorter):
                return True
    return False


def _exact_match_query(digits):
    variants = {digits, "+" + digits}
    if len(digits) == 11 and digits.startswith("1"):
        variants.update({digits[1:], "+" + digits[1:]})
    elif len(digits) == 10:
        variants.update({"1" + digits, "+1" + digits})
    if digits.startswith("0") and len(digits) > 1:
        variants.update({digits[1:], "+" + digits[1:]})
    terms = []
    for v in variants:
        if PHONE_TERM_RE.fullmatch(v):
            terms += (f"phone={v}", f"mobile_phone={v}")
    return "^OR".join(terms)


def _find_user_by_phone(raw_phone):
    digits = _digits(raw_phone)
    if len(digits) < PHONE_MIN_DIGITS:
        logger.warning("Phone too short for lookup (%s digits)", len(digits))
        return None
    candidates = []
    try:
        candidates = _query_users(_exact_match_query(digits), PHONE_CANDIDATE_LIMIT)
    except SnowHTTPError as e:
        if e.code != 403:
            raise
        logger.warning("Exact phone query blocked by ACL (403) - using LIKE pre-filter")
    if not candidates and len(digits) >= PHONE_LIKE_FALLBACK_DIGITS:
        suffix = digits[-PHONE_LIKE_FALLBACK_DIGITS:]
        candidates = _query_users(f"phoneLIKE{suffix}^ORmobile_phoneLIKE{suffix}", PHONE_CANDIDATE_LIMIT)
    for rec in candidates:
        if _phones_match(rec.get("phone"), digits) or _phones_match(rec.get("mobile_phone"), digits):
            return rec
    return None


def _find_user_by_upi(upi):
    candidates = _query_users(f"{SN_UPI_FIELD}={upi}", 1)
    return candidates[0] if candidates else None


def lookup_user(params):
    """Phone/ANI first; UPI alone as fallback.
    Returns (record, identifier_type, registered_by_phone)."""
    phone_raw = get_param(params, *PHONE_PARAM_KEYS)
    phone_tried = bool(_digits(phone_raw))
    if phone_tried:
        record = _find_user_by_phone(phone_raw)
        if record is not None:
            return record, "phone", True
    upi = get_param(params, *UPI_PARAM_KEYS)
    if upi:
        if not UPI_RE.match(upi):
            raise ValueError("invalid_upi")
        return _find_user_by_upi(upi), "upi", False
    return None, ("phone" if phone_tried else None), False


# --- Profile -------------------------------------------------------------------
def compute_user_status(start_date_raw):
    value = (start_date_raw or "").strip()
    if not value:
        return ""
    for fmt in SN_DATE_FORMATS:
        try:
            start_date = datetime.strptime(value, fmt).date()
            break
        except ValueError:
            continue
    else:
        logger.warning("Unparseable StartDate %r", value)
        return ""
    days = (datetime.now(timezone.utc).date() - start_date).days
    if days < 0:
        return "pre-hired"
    return "new-hired" if days <= NEW_HIRE_WINDOW_DAYS else "existing-user"


def _sanitised_record(record):
    """The FULL sys_user record exactly as ServiceNow returned it, with only
    the sensitive fields blanked."""
    record = dict(record)
    for field in SENSITIVE_FIELDS:
        if field in record:
            record[field] = ""
    return record


def _flat_record(record):
    """Full record flattened for Gateway callers: every field kept,
    reference fields ({"link", "value"}) reduced to their value string."""
    return {str(k): _extract_value(v) for k, v in _sanitised_record(record).items()}


def _build_caller_profile(record, registered_by_phone):
    v = lambda key: _extract_value(record.get(key))  # noqa: E731
    start_date = v(SN_START_DATE_FIELD)
    return {
        "FirstName": v("first_name"),
        "LastName": v("last_name"),
        "FullName": v("name"),
        "Email": v("email"),
        "Phone": v("phone") or v("mobile_phone"),
        "RegisteredCaller": "Yes" if registered_by_phone else "No",
        "UPI": v(SN_UPI_FIELD),
        "UserId": v(SN_USER_ID_FIELD),
        "FieldForce": "true" if v(SN_FIELD_FORCE_FIELD).lower() in ("true", "1") else "false",
        "StartDate": start_date,
        "UserStatus": compute_user_status(start_date),
        "Title": v("title"),
        "Department": v("u_function"),
        "EmployeeType": v("u_employee_type"),
        "City": v("city"),
        "State": v("u_state") or v("state"),
        "Country": v("country"),
        "TimeZone": v("time_zone"),
        "PreferredLanguage": v("preferred_language"),
        "ManagerSysId": v("manager"),
        "CostCenterSysId": v("cost_center"),
        "LocationSysId": v("location"),
        "SysId": v("sys_id"),
        "Active": v("active"),
        "VIP": v("vip"),
    }


# --- PhoneLookupStatus (added to EVERY flat response) -----------------------------
def _phone_lookup_status(resp):
    if resp.get("Status") == "Authenticated" and resp.get("RegisteredCaller") == "Yes":
        return "Matched"
    if resp.get("Error") in NO_MATCH_ERRORS:
        return "NotMatched"
    if resp.get("Status") == "Authenticated":
        return "UPIMatched"        # matched by UPI, not by phone (bot path only)
    return "Error"


# --- Contact-flow response shaping -------------------------------------------------
def _contact_flow_response(resp):
    """Compact, flow-safe map: fixed keys, string values, PhoneLookupStatus set.
    Matched only for an authenticated, phone-registered caller."""
    out = {k: str(resp.get(k, "") or "") for k in CF_KEYS}
    status = _phone_lookup_status(resp)
    if status == "UPIMatched":     # the flow only ever sends a phone; treat anything else as Error
        status = "Error"
    out["PhoneLookupStatus"] = status
    if status != "Matched":
        for k in CF_PROFILE_KEYS:
            out[k] = ""
    return out


# --- Invocation parsing ---------------------------------------------------------
def _is_agentcore_gateway(context):
    client_context = getattr(context, "client_context", None) if context is not None else None
    custom = getattr(client_context, "custom", None) if client_context is not None else None
    if not isinstance(custom, dict):
        return False
    return any(str(k).lower().startswith("bedrockagentcore") for k in custom)


def extract_parameters(event, context=None):
    if _is_agentcore_gateway(context):
        return (event if isinstance(event, dict) else {}), "mcp_gateway"
    if not isinstance(event, dict):
        return {}, "direct"
    if isinstance(event.get("parameters"), dict):
        return event["parameters"], "mcp_gateway"
    if "Details" in event or event.get("Name") == "ContactFlowEvent":
        details = event.get("Details") or {}
        params = dict(details.get("Parameters") or {})
        contact_data = details.get("ContactData") or {}
        params["_customer_num"] = (contact_data.get("CustomerEndpoint") or {}).get("Address", "")
        params["_contact_id"] = contact_data.get("ContactId", "")
        return params, "contact_flow"
    if isinstance(event.get("parameters"), list):
        return ({p["name"]: p.get("value") for p in event["parameters"]
                 if isinstance(p, dict) and "name" in p}, "bedrock_agent")
    return event, "direct"


# --- Responses -----------------------------------------------------------------
def _error_response(invocation_type, code, message, status_code=400):
    if invocation_type in FLAT_RESPONSE_TYPES:
        return {"Status": "Unauthenticated", "Error": code, "Message": message, "AuthResult": "Failure"}
    return {"statusCode": status_code, "body": {"status": "Unauthenticated", "message": message,
            "error_code": code, "auth_result": "Failure"}}


def _not_authenticated_response(invocation_type, identifier_type, reason="User is not registered."):
    if invocation_type in FLAT_RESPONSE_TYPES:
        return {"Status": "Unauthenticated", "Error": "UserNotRegistered", "Message": reason,
                "AuthResult": "Failure"}
    return {"statusCode": 404, "body": {"status": "Unauthenticated", "error_code": "UserNotRegistered",
            "identifier_type": identifier_type or "", "message": reason, "auth_result": "Failure"}}


def _profile_error_response(invocation_type, code, message, status_code=400):
    if invocation_type in FLAT_RESPONSE_TYPES:
        return {"Status": "Failure", "Error": code, "Message": message, "AuthResult": "Failure"}
    return {"statusCode": status_code, "body": {"success": False, "message": message, "error_code": code,
            "auth_result": "Failure"}}


# --- Authorization ---------------------------------------------------------------
def check_authorization(record):
    missing = [f for f in AUTH_REQUIRED_FIELDS if not _extract_value(record.get(f))]
    if missing:
        return False, "Missing mandatory field(s) for authorization: " + ", ".join(missing)
    if REQUIRE_ACTIVE_USER and _extract_value(record.get("active")).lower() not in ("true", "1"):
        return False, "User is not active."
    if REJECT_LOCKED_OUT_USER and _extract_value(record.get("locked_out")).lower() in ("true", "1"):
        return False, "User account is locked."
    return True, ""


def _safe_lookup(params, on_error):
    """Run lookup_user, mapping failures through on_error(code, message, status)."""
    try:
        return lookup_user(params), None
    except ValueError:
        return None, on_error("InvalidIdentifier", "Provided identifier failed validation.", 400)
    except DeadlineExceeded:
        logger.warning("Lookup stopped: contact-flow time budget exhausted")
        return None, on_error("Timeout", None, 504)
    except SnowHTTPError as e:
        logger.error("ServiceNow HTTP error %s", e.code)
        return None, on_error(f"HTTP{e.code}", None, 502)
    except (TimeoutError, OSError, http.client.HTTPException):
        logger.warning("ServiceNow network error/timeout", exc_info=True)
        return None, on_error("Timeout", None, 504)
    except Exception:
        logger.exception("Unexpected error during ServiceNow lookup")
        return None, on_error("LambdaException", None, 500)


def handle_authorize(params, invocation_type):
    def on_error(code, message, status):
        return _error_response(invocation_type, code, message or "Unable to verify user registration.", status)

    result, error = _safe_lookup(params, on_error)
    registered_by_phone = False
    if error is None:
        record, identifier_type, registered_by_phone = result
        if identifier_type is None:
            # Diagnostic only: key names and value lengths, never the values themselves.
            logger.warning("MissingIdentifier: param_keys=%s phone_len=%d upi_len=%d",
                           sorted(str(k) for k in (params or {})),
                           len(get_param(params, *PHONE_PARAM_KEYS)),
                           len(get_param(params, *UPI_PARAM_KEYS)))
            error = _error_response(invocation_type, "MissingIdentifier",
                                    "No phone (ANI) or UPI supplied. Do not repeat the phone lookup; "
                                    "keep any earlier lookup result and continue.", 400)
        elif record is None:
            error = _not_authenticated_response(invocation_type, identifier_type)
        else:
            authorized, reason = check_authorization(record)
            if not authorized:
                error = _not_authenticated_response(invocation_type, identifier_type, reason)
                # The record WAS returned by sys_user - AuthResult reports the lookup.
                if invocation_type in FLAT_RESPONSE_TYPES:
                    error["AuthResult"] = "Success"
                else:
                    error["body"]["auth_result"] = "Success"
    if error is not None:
        if invocation_type in FLAT_RESPONSE_TYPES:
            error["RegisteredCaller"] = "Yes" if registered_by_phone else "No"
        logger.info("Result: Unauthenticated (%s)", error.get("Error") or error.get("body", {}).get("error_code"))
        return error
    logger.info("Result: Authenticated via %s (sys_id=%s)", identifier_type, _extract_value(record.get("sys_id")))
    profile = _build_caller_profile(record, registered_by_phone)
    if invocation_type in FLAT_RESPONSE_TYPES:
        response = {} if invocation_type == "contact_flow" else _flat_record(record)
        response.update(profile)
        response["Status"] = "Authenticated"
        response["AuthResult"] = "Success"
        return response
    return {"statusCode": 200, "body": {"status": "Authenticated", "registered_caller": registered_by_phone,
            "sys_id": _extract_value(record.get("sys_id")), "profile": profile,
            "record": _sanitised_record(record), "auth_result": "Success"}}


def handle_get_user_profile(params, invocation_type):
    def on_error(code, message, status):
        return _profile_error_response(invocation_type, code, message or "Unable to retrieve user profile.", status)

    result, error = _safe_lookup(params, on_error)
    if error is not None:
        return error
    record, identifier_type, registered_by_phone = result
    if identifier_type is None:
        logger.warning("MissingIdentifier (profile): param_keys=%s", sorted(str(k) for k in (params or {})))
        return _profile_error_response(invocation_type, "MissingIdentifier", "No phone (ANI) or UPI supplied.", 400)
    if record is None:
        return _profile_error_response(invocation_type, "NotFound", "No matching user profile found.", 404)
    profile = _build_caller_profile(record, registered_by_phone)
    if invocation_type in FLAT_RESPONSE_TYPES:
        response = _flat_record(record)
        response.update(profile)
        response["Status"] = "success"
        response["AuthResult"] = "Success"
        return response
    return {"statusCode": 200, "body": {"success": True, "registered_caller": registered_by_phone,
            "result": [profile], "record": _sanitised_record(record), "auth_result": "Success"}}


# --- Entry point -----------------------------------------------------------------
def lambda_handler(event, context):
    if LOG_RAW_EVENT:
        logger.info("RAW EVENT = %s", json.dumps(event, default=str))
    params, invocation_type = extract_parameters(event, context)
    _set_budget(invocation_type)
    try:
        if invocation_type == "contact_flow":
            # The flow always runs the phone lookup; never a UPI or profile action.
            try:
                resp = handle_authorize(params, invocation_type)
            except Exception:
                logger.exception("Unexpected contact-flow failure")
                resp = {"Status": "Unauthenticated", "Error": "LambdaException", "AuthResult": "Failure"}
            out = _contact_flow_response(resp)
            logger.info("Build=%s invocation=contact_flow PhoneLookupStatus=%s Error=%s",
                        BUILD, out["PhoneLookupStatus"], out["Error"] or "-")
            return out
        action = ACTION_ALIASES.get(get_param(params, "action", "operation", "intent").lower(), "authorize")
        if action == "get_user_profile":
            return handle_get_user_profile(params, invocation_type)
        resp = handle_authorize(params, invocation_type)
        if invocation_type in FLAT_RESPONSE_TYPES:
            resp["PhoneLookupStatus"] = _phone_lookup_status(resp)
        logger.info("Build=%s invocation=%s PhoneLookupStatus=%s", BUILD, invocation_type,
                    resp.get("PhoneLookupStatus", "-") if isinstance(resp, dict) else "-")
        return resp
    finally:
        _set_budget(None)


handler = lambda_handler

logger.info("ServiceNow_UserLookUp build %s loaded", BUILD)

# Fetch the ServiceNow credentials during init, so provisioned-concurrency
# containers are ready before the first call. A failure here is retried
# lazily on the first request.
try:
    _get_auth_header()
except Exception:
    logger.warning("Credential prefetch at init failed; will retry on first request", exc_info=True)
