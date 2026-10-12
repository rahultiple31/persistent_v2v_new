"""Manage only this module's retrieval profile on its AI-agent ARNs."""

import json
import os
import subprocess
import sys
import time


class AwsCliError(RuntimeError):
    pass


def reconcile(query, action, aws):
    if action not in ("associate", "disassociate"):
        raise ValueError("Security profile action must be associate or disassociate.")
    if aws("sts", "get-caller-identity")["Account"] != query["account_id"]:
        raise ValueError("AWS CLI and Terraform must use the same AWS account.")

    agent_arns = list(dict.fromkeys(query["agent_arns"]))
    for arn in agent_arns:
        parts = arn.split(":", 5)
        if (
            len(parts) != 6
            or parts[2] != "wisdom"
            or parts[3] != query["region"]
            or parts[4] != query["account_id"]
            or not parts[5].startswith("ai-agent/")
        ):
            raise ValueError("AI-agent ARNs must match the provider account and region.")

    for arn in agent_arns:
        arguments = (
            "--instance-id", query["instance_id"],
            "--entity-type", "AI_AGENT",
            "--entity-arn", arn,
        )
        try:
            profiles = aws(
                "connect", "list-entity-security-profiles", *arguments
            )["SecurityProfiles"]
            attached = any(
                profile["Id"] == query["security_profile_id"] for profile in profiles
            )
            if attached == (action == "associate"):
                continue
            aws(
                "connect", action + "-security-profiles", *arguments,
                "--security-profiles", json.dumps([{"Id": query["security_profile_id"]}]),
            )
        except AwsCliError as error:
            # Old versions may already be gone when replacing/destroying the stack.
            if action == "disassociate" and "ResourceNotFoundException" in str(error):
                continue
            raise


def main():
    query = json.loads(os.environ["AI_SECURITY_QUERY"])
    action = os.environ["AI_SECURITY_ACTION"]

    def aws(service, operation, *arguments):
        command = [
            "aws", service, operation, *arguments,
            "--region", query["region"], "--output", "json",
            "--no-cli-pager", "--no-cli-auto-prompt",
        ]
        if query["aws_profile"]:
            command.extend(["--profile", query["aws_profile"]])
        for attempt in range(5):
            result = subprocess.run(
                command, capture_output=True, text=True, encoding="utf-8",
                env={**os.environ, "AWS_PAGER": "", "AWS_CLI_AUTO_PROMPT": "off"},
            )
            if not result.returncode:
                return json.loads(result.stdout) if result.stdout.strip() else {}
            error = result.stderr.strip()
            if (
                action == "associate"
                and "ResourceNotFoundException" in error
                and attempt < 4
            ):
                time.sleep(2 ** attempt)
                continue
            raise AwsCliError(error)

    reconcile(query, action, aws)
    print("Retrieval security profile " + action + " completed.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
