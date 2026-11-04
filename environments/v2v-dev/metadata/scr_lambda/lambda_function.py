"""
Copies Invoke-Lambda parameters into the contact's Amazon Q in Connect session.

Run after the "Connect assistant" block.

Lambda entry point: warmup_wrapper.handler
ORIGINAL_HANDLER: lambda_function.handler

Environment variables (all optional)
  NAMESPACE          Session-data namespace. Default "Custom".
  LOG_LEVEL          Default "INFO".
  API_TIMEOUT        Per-call read timeout in seconds. Default 1.5.
  API_MAX_ATTEMPTS   Total attempts per AWS call, INCLUDING the first. Default 2.
"""
import logging
import os
import re

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError, ParamValidationError

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

_NAMESPACE = os.environ.get("NAMESPACE", "Custom")

_MAX_VALUE_LEN = 4096

_BOTO_CONFIG = Config(
    connect_timeout=1,
    read_timeout=float(os.environ.get("API_TIMEOUT", "1.5")),
    retries={
        "total_max_attempts": int(os.environ.get("API_MAX_ATTEMPTS", "2")),
        "mode": "standard",
    },
    tcp_keepalive=True,
)

_connect = boto3.client("connect", config=_BOTO_CONFIG)
_qconnect = boto3.client("qconnect", config=_BOTO_CONFIG)

# arn:aws:wisdom:<region>:<account>:session/<assistant-id>/<session-id>
_SESSION_ARN_RE = re.compile(
    r"^arn:aws[A-Za-z\-]*:wisdom:[^:]+:\d+:session/"
    r"(?P<assistant_id>[^/]+)/(?P<session_id>[^/]+)$"
)


def _get_session_ids(instance_arn, contact_id):
    """Resolve the Q in Connect session associated with the contact."""
    response = _connect.describe_contact(
        InstanceId=instance_arn,
        ContactId=contact_id,
    )
    contact = response.get("Contact") or {}
    session_arn = (contact.get("WisdomInfo") or {}).get("SessionArn")
    if not session_arn:
        raise RuntimeError(
            "Contact has no WisdomInfo.SessionArn; "
            "run the 'Connect assistant' block first."
        )
    match = _SESSION_ARN_RE.fullmatch(session_arn)
    if not match:
        raise ValueError("Unrecognised Q in Connect session ARN.")
    return match["assistant_id"], match["session_id"]


def _error(code):
    return {"status": "error", "errorCode": code}


def handler(event, _context):
    try:
        details = event["Details"]
        contact_data = details["ContactData"]
        instance_arn = contact_data["InstanceARN"]
        contact_id = contact_data["ContactId"]
        parameters = details.get("Parameters")
    except (KeyError, TypeError, AttributeError):
        logger.error("Malformed event - not an Amazon Connect contact-flow invocation")
        return _error("InvalidEvent")

    if parameters is None:
        parameters = {}

    if (
        not isinstance(instance_arn, str)
        or not instance_arn.strip()
        or not isinstance(contact_id, str)
        or not contact_id.strip()
        or not isinstance(parameters, dict)
    ):
        logger.error("Invalid contact identifiers or invocation parameters")
        return _error("InvalidEvent")

    # Empty values are omitted. Existing session keys are not cleared.
    data = []
    skipped = []
    for key, raw_value in parameters.items():
        value = "" if raw_value is None else str(raw_value).strip()
        if not value:
            skipped.append(str(key))
            continue
        data.append({
            "key": str(key),
            "value": {
                "stringValue": value[:_MAX_VALUE_LEN],
            },
        })
    if skipped:
        logger.warning(
            "Contact %s: empty values skipped for keys: %s",
            contact_id,
            ",".join(skipped),
        )
    if not data:
        return {"status": "success", "keysSet": ""}
    keys = ",".join(item["key"] for item in data)

    try:
        assistant_id, session_id = _get_session_ids(instance_arn, contact_id)
        _qconnect.update_session_data(
            assistantId=assistant_id,
            sessionId=session_id,
            namespace=_NAMESPACE,
            data=data,
        )
    except ClientError as exc:
        error = exc.response.get("Error", {})
        code = error.get("Code") or "ClientError"
        logger.error(
            "AWS request failed for contact %s: %s",
            contact_id,
            code,
        )
        return _error(code)
    except ParamValidationError:
        logger.error(
            "Invalid AWS request parameters for contact %s.",
            contact_id,
        )
        return _error("ParamValidationError")
    except BotoCoreError as exc:
        code = type(exc).__name__
        logger.error(
            "AWS call failed for contact %s: %s",
            contact_id,
            code,
        )
        return _error(code)
    except (ValueError, RuntimeError) as exc:
        logger.error(
            "Session lookup failed for contact %s: %s",
            contact_id,
            exc,
        )
        return _error(type(exc).__name__)

    logger.info(
        "Session %s updated for contact %s; keys: %s",
        session_id,
        contact_id,
        keys,
    )
    return {"status": "success", "keysSet": keys}


lambda_handler = handler
