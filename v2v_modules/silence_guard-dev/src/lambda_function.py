"""silence_guard v11 - advisory guard for the Complete / Escalate hand-back.

Why v11: v10 BLOCKED the call ("I can't safely continue this call") on soft defects such as
an intent label with a stray space/case difference, a short CallSummary, or VerifiedVia
missing. Blocking never helps the caller: it only disconnects them. v11 therefore:
  * normalises values (case, whitespace, dash variants) before checking;
  * NEVER blocks by default - it always returns GuardAllowed="true" and reports any
    problems in GuardReason / CloudWatch so they can be fixed in the prompt;
  * keeps a STRICT_MODE env var (true/false, default false) to restore blocking for a
    test environment only;
  * fails open on any internal error.
Output is a flat string map (flow uses STRING_MAP):
  {"GuardAllowed": "true"|"false", "GuardReason": "...", "NormalizedIntent": "..."}
"""
import logging
import os
import re

log = logging.getLogger()
log.setLevel(logging.INFO)

STRICT_MODE = os.environ.get("STRICT_MODE", "false").strip().lower() == "true"

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
    "System - Bot Unavailable",
    # Reserved for the LATAM Veeva / MedCom journeys (labels to be confirmed).
    "Veeva - LATAM Helpdesk", "Medcom - LATAM Helpdesk",
    "Veeva - Live Agent", "Medcom - Live Agent",
}
CLOSE_ONLY = {"Patient/Customer - Misroute", "Unverified - Misroute", "Out of Scope - Unrelated Request"}
ROUTING_VALUES = {"", "HR", "FieldForce", "Veeva", "Medcom"}
CALLER_REQUEST = "live agent - caller request"
FILLERS = {"placeholder", "pending", "unknown", "n/a", "na", "test", "null", "none", "tbd"}

_DASHES = re.compile(r"\s*[-\u2010-\u2015]\s*")
_SPACES = re.compile(r"\s+")


def _norm(value):
    value = _SPACES.sub(" ", str(value or "")).strip()
    return _DASHES.sub(" - ", value)


_LOOKUP = {i.casefold(): i for i in BASE_INTENTS}


def _canonical_intent(intent):
    key = _norm(intent).casefold()
    if key in _LOOKUP:
        return _LOOKUP[key]
    if key.startswith(CALLER_REQUEST):
        rest = key[len(CALLER_REQUEST):].lstrip(" -")
        if not rest or rest in _LOOKUP:
            return "Live Agent - Caller Request" + (" - " + _LOOKUP[rest] if rest else "")
    return None


def _check(p):
    expected = _norm(p.get("ExpectedTool"))
    tool = _norm(p.get("Tool"))
    intent_raw = _norm(p.get("Intent"))
    summary = _norm(p.get("CallSummary"))
    routing = _norm(p.get("RoutingIntent"))
    region = _norm(p.get("region")).upper()
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
    if _norm(p.get("VerificationStatus")) == "Authenticated" and _norm(p.get("VerifiedVia")) not in ("Phone", "UPI"):
        issues.append("verified_without_method")
    if expected == "Complete" and routing:
        issues.append("routing_intent_on_complete")
    if routing not in ROUTING_VALUES:
        issues.append("routing_value_unknown")
    if routing in ("Veeva", "Medcom") and region != "LATAM":
        issues.append("veeva_medcom_outside_latam")
    return issues, intent or intent_raw


def lambda_handler(event, context):
    try:
        params = (event.get("Details") or {}).get("Parameters") or {}
        issues, intent = _check(params)
        allowed = not (STRICT_MODE and issues)
        log.info("guard contact=%s expected=%s tool=%s intent=%r routing=%s region=%s allowed=%s issues=%s",
                 params.get("ContactId"), params.get("ExpectedTool"), params.get("Tool"),
                 params.get("Intent"), params.get("RoutingIntent"), params.get("region"),
                 allowed, issues)
        return {"GuardAllowed": "true" if allowed else "false",
                "GuardReason": ",".join(issues) or "ok",
                "NormalizedIntent": intent or ""}
    except Exception as exc:  # never let a guard bug cut a call
        log.exception("guard error, failing open")
        return {"GuardAllowed": "true", "GuardReason": "guard_error:" + type(exc).__name__,
                "NormalizedIntent": ""}
