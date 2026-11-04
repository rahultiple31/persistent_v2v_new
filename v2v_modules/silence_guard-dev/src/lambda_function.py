"""silence_guard v13 - advisory guard for the Complete / Escalate hand-back.

Normalizes lookup keys and incoming intents consistently, including
"Password Reset - PingID Re-enable".

Defaults to advisory mode. STRICT_MODE=true enables blocking when issues
are detected. Internal errors always fail open.

Returns a flat string map for Amazon Connect STRING_MAP responses.

Lambda entry point: warmup_wrapper.handler
ORIGINAL_HANDLER: lambda_function.lambda_handler
"""
import logging
import os
import re

log = logging.getLogger()
log.setLevel(logging.INFO)

STRICT_MODE = os.environ.get(
    "STRICT_MODE",
    "false",
).strip().lower() == "true"

BASE_INTENTS = {
    "Password Reset - Pre Hire", "Password Reset - New Hire", "Password Reset - Existing User",
    "Password Reset - Manager Code", "Password Reset - Vendor System", "Password Reset - MFA/PingID",
    "Password Reset - PingID Re-enable",
    "Techspot - Device Health", "Techspot - Applications", "Techspot - ComplianceWire",
    "Techspot - External Access", "Techspot - Other IT", "Techspot - VDI", "Techspot - Network",
    "Techspot - Teams Handoff",
    "HR - Payroll", "HR - Benefits", "HR - Verification", "HR - Lifecycle",
    "HR - LMS/ComplianceWire", "HR - Equipment Return", "HR - Unverified",
    "Live Agent - Identity Sync", "Live Agent - Hardware", "Live Agent - Mobility",
    "Live Agent - Manufacturing", "Live Agent - M&A",
    "Field Force - Direct Routing",
    "Other - Case Status", "Other - Duplicate", "Other - Catalogue Request",
    "Record Conflict - Live Agent", "Live Agent - Caller Request",
    "Patient/Customer - Misroute", "Unverified - Misroute", "Unverified - Manufacturing",
    "Unverified - M&A", "Unverified - Verification Failed", "Unverified - Lookup Error",
    "Out of Scope - Unrelated Request",
    "Out of Scope - Medical Request",                       # v12: prompt v50 label
    "Out of Scope - Unverified/WrongNumber Misroute",       # v12: prompt v50 label
    "System - Bot Unavailable",
    "Veeva - LATAM Helpdesk", "Medcom - LATAM Helpdesk",
    "Veeva - Live Agent", "Medcom - Live Agent",
}
# Intents the prompt only ever ends with Complete (never Escalate).
CLOSE_ONLY = {
    "Patient/Customer - Misroute", "Unverified - Misroute", "Out of Scope - Unrelated Request",
    "Out of Scope - Medical Request", "Out of Scope - Unverified/WrongNumber Misroute",
    "Unverified - Verification Failed",
}
ROUTING_VALUES = {"", "HR", "FieldForce", "Veeva", "Medcom"}
LATAM_INTENT = {"Veeva": "Veeva - LATAM Helpdesk", "Medcom": "Medcom - LATAM Helpdesk"}
CALLER_REQUEST = "live agent - caller request"
FILLERS = {"placeholder", "pending", "unknown", "n/a", "na", "test", "null", "none", "tbd"}

_DASHES = re.compile(r"\s*[-\u2010-\u2015]\s*")
_SPACES = re.compile(r"\s+")


def _norm(value):
    value = _SPACES.sub(" ", str(value or "")).strip()
    return _DASHES.sub(" - ", value)


# Normalize both lookup keys and incoming intents using the same function.
_LOOKUP = {
    _norm(intent).casefold(): intent
    for intent in BASE_INTENTS
}


def _canonical_intent(intent):
    key = _norm(intent).casefold()
    if key in _LOOKUP:
        return _LOOKUP[key]
    if key.startswith(CALLER_REQUEST):
        rest = key[len(CALLER_REQUEST):].lstrip(" -")
        if not rest or rest in _LOOKUP:
            return (
                "Live Agent - Caller Request"
                + (" - " + _LOOKUP[rest] if rest else "")
            )
    return None


def _check(parameters):
    expected = _norm(parameters.get("ExpectedTool"))
    tool = _norm(parameters.get("Tool"))
    intent_raw = _norm(parameters.get("Intent"))
    summary = _norm(parameters.get("CallSummary"))
    routing = _norm(parameters.get("RoutingIntent"))
    region = _norm(parameters.get("region")).upper()
    verified = (
        _norm(parameters.get("VerificationStatus")) == "Authenticated"
    )
    issues = []

    if expected not in ("Complete", "Escalate"):
        return issues, intent_raw
    if tool.casefold() != expected.casefold():
        issues.append("tool_mismatch")

    intent = _canonical_intent(intent_raw) if intent_raw else None
    if not intent_raw:
        issues.append("intent_missing")
    elif intent is None:
        issues.append("intent_unknown")
    elif expected == "Escalate" and intent in CLOSE_ONLY:
        issues.append("close_only_intent_on_escalate")

    if len(summary) < 20 or summary.casefold() in FILLERS:
        issues.append("summary_short")
    if verified and _norm(parameters.get("VerifiedVia")) not in (
        "Phone",
        "UPI",
    ):
        issues.append("verified_without_method")
    if expected == "Complete" and routing:
        issues.append("routing_intent_on_complete")
    if routing not in ROUTING_VALUES:
        issues.append("routing_value_unknown")

    # Routing consistency (advisory only)
    if routing in ("Veeva", "Medcom"):
        if region != "LATAM":
            issues.append("veeva_medcom_outside_latam")
        if intent and intent != LATAM_INTENT[routing]:
            issues.append("routing_intent_label_mismatch")
    if routing == "FieldForce":
        if not verified:
            issues.append("fieldforce_unverified")
        if intent and intent != "Field Force - Direct Routing":
            issues.append("routing_intent_label_mismatch")
    if routing == "HR" and intent and not intent.startswith("HR - "):
        issues.append("routing_intent_label_mismatch")

    return issues, intent or intent_raw


def lambda_handler(event, context):
    try:
        parameters = (
            (event.get("Details") or {}).get("Parameters") or {}
        )

        issues, intent = _check(parameters)
        allowed = not (STRICT_MODE and issues)
        log.info(
            "guard contact=%s expected=%s tool=%s intent=%r "
            "routing=%s region=%s allowed=%s issues=%s",
            parameters.get("ContactId"),
            parameters.get("ExpectedTool"),
            parameters.get("Tool"),
            parameters.get("Intent"),
            parameters.get("RoutingIntent"),
            parameters.get("region"),
            allowed,
            issues,
        )
        return {
            "GuardAllowed": "true" if allowed else "false",
            "GuardReason": ",".join(issues) or "ok",
            "NormalizedIntent": intent or "",
        }
    except Exception as exc:
        # An internal guard error must not interrupt the call.
        log.exception("guard error, failing open")
        return {
            "GuardAllowed": "true",
            "GuardReason": "guard_error:" + type(exc).__name__,
            "NormalizedIntent": "",
        }
