import json
import logging
import os
import time
from datetime import datetime

import boto3

# Configure logger from env var (default INFO)
logLevel = os.environ.get("LOG_LEVEL", "INFO").upper()
logger = logging.getLogger()
logger.setLevel(getattr(logging, logLevel, logging.INFO))

# Initialize outside handler for reuse across warm invocations
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TableName"])

# TTL duration in seconds from env var (default 24 hours)
TTL_SECONDS = int(os.environ.get("TTL_SECONDS", "86400"))

DATE_FORMAT = "%m/%d/%Y %H:%M:%S"


def date_diff_in_seconds(dt2, dt1):
    """Return difference between two datetimes in seconds."""
    diff = dt2 - dt1
    logger.debug("timedelta: %s", diff)
    return int(diff.total_seconds())


def to_int(value, default=0):
    """Safely convert string/float/empty values to int."""
    try:
        if value is None or str(value).strip() == "":
            return default
        return int(float(value))
    except (ValueError, TypeError):
        logger.warning("Invalid numeric value: %s, using default %s", value, default)
        return default


def format_ewt(total_seconds):
    """
    Convert seconds to readable text.
    Examples:
        261 -> '4 minutes 21 seconds'
        34  -> '34 seconds'
        60  -> '1 minute'
        61  -> '1 minute 1 second'
        0   -> '0 seconds'
    """
    total_seconds = max(int(total_seconds), 0)
    minutes, seconds = divmod(total_seconds, 60)

    parts = []
    if minutes > 0:
        parts.append(f"{minutes} minute{'s' if minutes != 1 else ''}")
    if seconds > 0 or minutes == 0:
        parts.append(f"{seconds} second{'s' if seconds != 1 else ''}")

    return " ".join(parts)


def lambda_handler(event, context):
    logger.info("Received event: %s", json.dumps(event))

    details = event.get("Details", {})
    params = details.get("Parameters", {})
    contact_id = details.get("ContactData", {}).get("ContactId")
    invocation_type = params.get("invocationType")

    logger.info("Invocation Type: %s, ContactId: %s", invocation_type, contact_id)

    if not contact_id:
        logger.error("ContactId missing in event")
        return {"error": "ContactId missing"}

    # ---------------- putQueue ----------------
    if invocation_type == "putQueue":
        now = datetime.now()
        ttl_value = int(time.time()) + TTL_SECONDS

        response = table.update_item(
            Key={"callId": contact_id},
            UpdateExpression="SET times = :val1, #ttl = :ttl",
            ExpressionAttributeNames={"#ttl": "ttl"},
            ExpressionAttributeValues={
                ":val1": now.strftime(DATE_FORMAT),
                ":ttl": ttl_value,
            },
            ReturnValues="ALL_NEW",
        )
        item = response.get("Attributes", {})
        logger.debug("Updated item: %s, TTL: %s", item, ttl_value)

        return {
            "callId": str(item.get("callId", contact_id)),
            "times": str(item.get("times", "")),
        }

    # ---------------- getEWT ----------------
    elif invocation_type == "getEWT":
        queue_time = to_int(params.get("queue_time"), 0)
        queue_position = to_int(params.get("positionInQueue"), 1)

        logger.debug(
            "Input values - queue_time: %s, position_in_queue: %s",
            queue_time, queue_position
        )

        first_call = table.get_item(Key={"callId": contact_id})
        item = first_call.get("Item")

        if not item or "times" not in item:
            logger.error("No queue entry time found for ContactId: %s", contact_id)
            return {
                "callId": contact_id,
                "ewt": format_ewt(0),
                "ewtSeconds": "0",
                "positionInQueue": str(queue_position),
            }

        first_call_time = datetime.strptime(item["times"], DATE_FORMAT)
        now = datetime.now()
        dif_seconds = date_diff_in_seconds(now, first_call_time)

        logger.debug("firstCallTime: %s, difSeconds: %s", first_call_time, dif_seconds)

        # EWT = longest wait time in queue - time already spent; never negative
        ewt = max(queue_time - dif_seconds, 0)
        ewt_text = format_ewt(ewt)

        logger.info("EWT seconds: %s, EWT text: %s", ewt, ewt_text)

        response = table.update_item(
            Key={"callId": contact_id},
            UpdateExpression="SET ewt = :val1",
            ExpressionAttributeValues={":val1": ewt},
            ReturnValues="ALL_NEW",
        )
        logger.debug("Updated item: %s", response.get("Attributes"))

        # Amazon Connect expects flat key/value string pairs
        return {
            "callId": contact_id,
            "ewt": ewt_text,
            "ewtSeconds": str(ewt),
            "positionInQueue": str(queue_position),
        }

    # ---------------- Unsupported ----------------
    else:
        logger.error("Unsupported invocationType: %s", invocation_type)
        return {"error": f"Unsupported invocationType: {invocation_type}"}
