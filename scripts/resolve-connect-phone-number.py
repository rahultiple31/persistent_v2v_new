"""Resolve an already-claimed Connect number for a Terraform external data source."""

import json
import re
import subprocess
import sys


UUID_PATTERN = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"


def resolve_phone_number(query, runner=None):
    instance_id = query["instance_id"]
    phone_number = query["phone_number"]
    region = query["region"]

    if not re.fullmatch(UUID_PATTERN, instance_id):
        raise ValueError("instance_id must be an Amazon Connect instance UUID")
    if not re.fullmatch(r"\+[1-9][0-9]{1,14}", phone_number):
        raise ValueError("phone_number must use E.164 format without spaces or hyphens")
    if not re.fullmatch(r"[a-z]{2}(?:-[a-z]+)+-[0-9]+", region):
        raise ValueError("region must be a valid AWS region name")

    runner = runner or subprocess.run
    result = runner([
        "aws", "connect", "list-phone-numbers-v2",
        "--region", region,
        "--instance-id", instance_id,
        "--phone-number-prefix", phone_number,
        "--output", "json",
        "--no-cli-pager",
    ], text=True, capture_output=True)

    if result.returncode:
        raise RuntimeError(
            "Unable to resolve the claimed Connect phone number: " + result.stderr.strip()
        )

    numbers = json.loads(result.stdout).get("ListPhoneNumbersSummaryList", [])
    matches = [item for item in numbers if item.get("PhoneNumber") == phone_number]
    if len(matches) != 1:
        raise ValueError(
            f"Expected one claimed number matching {phone_number} in Connect instance "
            f"{instance_id}; found {len(matches)}. Verify the number is claimed by this instance."
        )

    phone_number_id = matches[0].get("PhoneNumberId", "")
    if not re.fullmatch(UUID_PATTERN, phone_number_id):
        raise ValueError("AWS returned an invalid phone-number resource UUID")

    return {"phone_number_id": phone_number_id}


def main():
    try:
        result = resolve_phone_number(json.load(sys.stdin))
    except (ValueError, KeyError, RuntimeError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
