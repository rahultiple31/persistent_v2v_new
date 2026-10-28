"""Validate preparatory and full-stack V2V deletion plans for dev/dev-nsso."""

import json
import re
import sys


BUCKET_ADDRESS = re.compile(
    r"module\.(?:s3|s3_v2v)\[0\]\.aws_s3_bucket\."
    r"(?:webapp|webapp_logs|v2v|v2v_logs)"
)
ALLOWED_MODULE_PREFIXES = (
    "module.s3[0].", "module.s3_v2v[0].",
    "module.cloudfront[0].", "module.cloudfront_v2v[0].",
    "module.cognito[0].", "module.cognito_v2v[0].",
    "module.iam[0].", "module.iam_v2v[0].",
    "module.ssm[0].", "module.ssm_v2v[0].",
)
RETIRED_ASSET_ADDRESSES = {
    "module.s3[0].aws_s3_object.webapp_assets",
    "module.s3_v2v[0].aws_s3_object.v2v_assets",
}


def reject(message):
    raise ValueError(message)


def validate(plan, choice, environment):
    if choice not in {"prepare-destroy-v2v", "destroy-v2v-stack"}:
        reject(f"Unsupported V2V cleanup choice: {choice}")
    if environment not in {"dev", "dev-nsso"}:
        reject(f"Unsupported V2V cleanup environment: {environment}")

    variables = plan.get("variables", {})
    expected = {
        "environment": environment,
        "enabled_modules": ["v2v"],
        "force_destroy_v2v_buckets": True,
        "destroy_v2v_stack": choice == "destroy-v2v-stack",
    }
    for name, expected_value in expected.items():
        actual = variables.get(name, {}).get("value")
        if actual != expected_value:
            reject(f"Plan has unexpected {name}: {actual!r}")

    deletions = []
    for item in plan.get("resource_changes", []):
        address = item["address"]
        change = item["change"]
        actions = change["actions"]
        if actions in (["no-op"], ["read"]):
            continue

        if choice == "prepare-destroy-v2v":
            before = change.get("before") or {}
            after = change.get("after") or {}
            if not (
                BUCKET_ADDRESS.fullmatch(address)
                and actions == ["update"]
                and before.get("force_destroy") is False
                and after.get("force_destroy") is True
                and {k: v for k, v in before.items() if k != "force_destroy"}
                == {k: v for k, v in after.items() if k != "force_destroy"}
            ):
                reject(f"Preparation plan changes an unrelated resource: {address}: {actions}")
            continue

        if actions == ["forget"] and address in RETIRED_ASSET_ADDRESSES:
            continue
        if actions != ["delete"] or not (
            address.startswith(ALLOWED_MODULE_PREFIXES)
            or address == "terraform_data.v2v_settings[0]"
        ):
            reject(f"Destroy plan changes an unrelated resource: {address}: {actions}")
        if BUCKET_ADDRESS.fullmatch(address) and (
            (change.get("before") or {}).get("force_destroy") is not True
        ):
            reject(f"S3 bucket was not prepared for destruction: {address}")
        deletions.append(address)

    if choice == "destroy-v2v-stack" and not deletions:
        reject("Destroy plan contains no V2V resources to delete")
    return len(deletions)


def main():
    if len(sys.argv) != 3:
        print("Usage: validate-dev-v2v-cleanup-plan.py CHOICE ENVIRONMENT", file=sys.stderr)
        return 2
    try:
        count = validate(json.load(sys.stdin), sys.argv[1], sys.argv[2])
    except (ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        print(f"V2V cleanup plan rejected: {exc}", file=sys.stderr)
        return 1
    print(f"Validated {sys.argv[1]}: {count} resource deletions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
