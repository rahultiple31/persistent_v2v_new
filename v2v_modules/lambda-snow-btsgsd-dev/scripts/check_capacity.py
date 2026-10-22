"""Read Lambda capacity using the deployment identity; no AWS resources are changed."""

import json
import subprocess
import sys


class AwsCliError(RuntimeError):
    pass


def aws_json(region, *arguments):
    result = subprocess.run(
        ["aws", *arguments, "--region", region, "--output", "json", "--no-cli-pager"],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if result.returncode:
        raise AwsCliError(result.stderr.strip())
    return json.loads(result.stdout)


def check_capacity(query):
    region = query["region"]
    identity = aws_json(region, "sts", "get-caller-identity")
    if identity["Account"] != query["account_id"]:
        raise RuntimeError("AWS CLI and Terraform must use the same AWS account.")

    settings = aws_json(region, "lambda", "get-account-settings")["AccountLimit"]
    try:
        concurrency = aws_json(
            region, "lambda", "get-function-concurrency",
            "--function-name", query["function_name"],
        )
    except AwsCliError as error:
        if "(ResourceNotFoundException)" not in str(error):
            raise
        concurrency = {}

    current = concurrency.get("ReservedConcurrentExecutions", 0)
    unreserved = settings["UnreservedConcurrentExecutions"]
    return {
        "unreserved": str(unreserved),
        "current_reservation": str(current),
        "maximum_reservation": str(max(0, unreserved + current - 100)),
    }


if __name__ == "__main__":
    try:
        print(json.dumps(check_capacity(json.load(sys.stdin))))
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"Lambda concurrency capacity check failed: {error}", file=sys.stderr)
        sys.exit(1)
