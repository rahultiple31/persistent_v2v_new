"""Grant MCP tool access through Admin for the configured support agent."""

import json
import os
import subprocess
import sys
import time


def aws(region, service, operation, *, aws_profile="", **payload):
    command = [
        "aws", service, operation,
        "--region", region,
        "--cli-input-json", json.dumps(payload),
        "--output", "json", "--no-cli-pager", "--no-cli-auto-prompt",
    ]
    if aws_profile:
        command.extend(["--profile", aws_profile])
    result = subprocess.run(
        command, capture_output=True, text=True, timeout=60, check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f"{operation} failed.")
    return json.loads(result.stdout) if result.stdout.strip() else {}


def grant(config, aws_call=aws, sleep=time.sleep):
    instance_arn = config["connect_instance_arn"]
    parts = instance_arn.split(":", 5)
    if len(parts) != 6 or parts[2] != "connect" or not parts[5].startswith("instance/"):
        raise ValueError("Provide a valid Connect instance ARN.")
    region, account = parts[3:5]
    instance_id = parts[5].split("/", 1)[1]
    profile = config.get("aws_profile", "")
    if aws_call(region, "sts", "get-caller-identity", aws_profile=profile)["Account"] != account:
        raise RuntimeError("AWS credentials do not match the Connect account.")

    namespace = config["namespace"]
    required_tools = set(config["tool_names"])
    if not namespace or not required_tools or any(not tool for tool in required_tools):
        raise ValueError("MCP namespace and tool names are required.")

    expected_prefix = f"arn:{parts[1]}:wisdom:{region}:{account}:ai-agent/"
    agent_arns = set(config["agent_arns"])
    if not agent_arns or any(not arn.startswith(expected_prefix) for arn in agent_arns):
        raise ValueError("AI agent ARNs must match the account and region.")
    # Each grant is scoped to one agent's latest and published versions.
    if len({arn.rsplit(":", 1)[0] for arn in agent_arns}) != 1 or any(
        not (arn.endswith(":$LATEST") or arn.rsplit(":", 1)[-1].isdigit())
        for arn in agent_arns
    ):
        raise ValueError("Provide version-qualified ARNs belonging to one AI agent.")

    def connect(operation, **payload):
        return aws_call(
            region, "connect", operation,
            aws_profile=profile, InstanceId=instance_id, **payload,
        )

    admins = [
        item for item in connect("list-security-profiles")["SecurityProfileSummaryList"]
        if item["Name"] == "Admin"
    ]
    if len(admins) != 1:
        raise RuntimeError("Expected exactly one existing Admin profile.")
    admin_id = admins[0]["Id"]

    def applications():
        return connect(
            "list-security-profile-applications", SecurityProfileId=admin_id,
        )["Applications"]

    existing = applications()
    updated = [dict(application) for application in existing]
    matches = [application for application in updated if application["Namespace"] == namespace]
    if len(matches) > 1:
        raise RuntimeError("Duplicate application namespace in Admin profile.")
    if matches:
        target = matches[0]
        if target.get("Type") not in (None, "MCP"):
            raise RuntimeError("The application namespace is not an MCP server.")
    else:
        target = {"Namespace": namespace, "ApplicationPermissions": []}
        updated.append(target)
    target["Type"] = "MCP"
    target["ApplicationPermissions"] = sorted(
        set(target.get("ApplicationPermissions", [])) | required_tools
    )

    # Only Applications is updated; existing application and tool grants are merged.
    if updated != existing:
        connect("update-security-profile", SecurityProfileId=admin_id, Applications=updated)

    def verify(predicate, message):
        for attempt in range(6):
            if predicate():
                return
            if attempt < 5:
                sleep(2)
        raise RuntimeError(message)

    verify(
        lambda: any(
            application["Namespace"] == namespace
            and application.get("Type") == "MCP"
            and required_tools.issubset(application.get("ApplicationPermissions", []))
            for application in applications()
        ),
        "Admin MCP tool permissions were not verified.",
    )

    def assigned_profiles(agent_arn):
        response = connect(
            "list-entity-security-profiles", EntityType="AI_AGENT", EntityArn=agent_arn,
        )
        return {item["Id"] for item in response["SecurityProfiles"]}

    for agent_arn in sorted(agent_arns):
        if admin_id not in assigned_profiles(agent_arn):
            connect(
                "associate-security-profiles", EntityType="AI_AGENT", EntityArn=agent_arn,
                SecurityProfiles=[{"Id": admin_id}],
            )
        verify(
            lambda: admin_id in assigned_profiles(agent_arn),
            f"Admin assignment was not verified: {agent_arn}",
        )
    return len(agent_arns)


def main():
    config = json.loads(os.environ["SUPPORT_AGENT_ADMIN_ACCESS"])
    count = grant(config)
    print(f"Admin MCP tool access verified for {count} support-agent versions.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(f"Support-agent Admin MCP access failed: {error}", file=sys.stderr)
        sys.exit(1)
