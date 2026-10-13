"""Assign Admin to custom AI agents before detaching their previous profiles."""

import json
import os
import subprocess
import sys
import time


def migrate(config, aws, log=print, sleep=time.sleep):
    parts = config["connect_instance_arn"].split(":", 5)
    if len(parts) != 6 or parts[2] != "connect" or parts[3] != config["region"] or not parts[5].startswith("instance/"):
        raise ValueError("Connect instance ARN must match the configured region.")
    instance_id = parts[5].split("/", 1)[1]
    account = parts[4]
    if aws("sts", "get-caller-identity")["Account"] != account:
        raise ValueError("AWS CLI credentials must match the Connect instance account.")

    admin_id = config["admin_profile_id"]
    profile = aws(
        "connect", "describe-security-profile", "--instance-id", instance_id,
        "--security-profile-id", admin_id,
    )["SecurityProfile"]
    if profile["SecurityProfileName"] != "Admin":
        raise ValueError("The selected security profile must be the existing Admin profile.")

    assistant_id = config["assistant_id"]
    assistant = aws("qconnect", "get-assistant", "--assistant-id", assistant_id)["assistant"]
    associations = aws(
        "connect", "list-integration-associations", "--instance-id", instance_id,
        "--integration-type", "WISDOM_ASSISTANT",
    )["IntegrationAssociationSummaryList"]
    if not any(item["IntegrationArn"] == assistant["assistantArn"] for item in associations):
        raise ValueError("The configured assistant is not associated with this Connect instance.")

    def attached(arn):
        result = aws(
            "connect", "list-entity-security-profiles", "--instance-id", instance_id,
            "--entity-type", "AI_AGENT", "--entity-arn", arn,
        )
        return {item["Id"] for item in result["SecurityProfiles"]}

    def verify(arn, predicate, message):
        for attempt in range(6):
            if predicate(attached(arn)):
                return
            if attempt < 5:
                sleep(2)
        raise RuntimeError(f"{message}: {arn}")

    agents = aws(
        "qconnect", "list-ai-agents", "--assistant-id", assistant_id, "--origin", "CUSTOMER",
    )["aiAgentSummaries"]
    targets = {}
    for agent in agents:
        # Check origin defensively, even though the list call already filters it.
        if agent.get("origin", "CUSTOMER") != "CUSTOMER":
            continue
        orchestration = agent.get("configuration", {}).get("orchestrationAIAgentConfiguration", {})
        if orchestration.get("connectInstanceArn", config["connect_instance_arn"]) != config["connect_instance_arn"]:
            log(f"Skipping {agent['name']}: configured for a different Connect instance.")
            continue
        arn = agent["aiAgentArn"]
        expected_prefix = f"arn:{parts[1]}:wisdom:{config['region']}:{account}:ai-agent/{assistant_id}/"
        if not arn.startswith(expected_prefix) or ":" in arn[len(expected_prefix):]:
            raise ValueError(f"AI agent ARN does not match the configured assistant/account/region: {arn}")
        versions = aws(
            "qconnect", "list-ai-agent-versions", "--assistant-id", assistant_id,
            "--ai-agent-id", agent["aiAgentId"], "--origin", "CUSTOMER",
        )["aiAgentVersionSummaries"]
        arns = [arn + ":$LATEST"] + [f"{arn}:{item['versionNumber']}" for item in versions]
        for version_arn in arns:
            targets[version_arn] = attached(version_arn)

    # Discover all existing assignments before any writes. Establish and verify
    # Admin access on every version before detaching any previous profiles.
    for arn, profiles in targets.items():
        if admin_id not in profiles:
            log(f"Assigning Admin security profile to {arn}.")
            aws(
                "connect", "associate-security-profiles", "--instance-id", instance_id,
                "--entity-type", "AI_AGENT", "--entity-arn", arn,
                "--security-profiles", json.dumps([{"Id": admin_id}]),
            )
        verify(arn, lambda ids: admin_id in ids, "Admin assignment could not be verified; previous profiles were retained")

    for arn, profiles in targets.items():
        previous = sorted(profiles - {admin_id})
        for start in range(0, len(previous), 10):
            batch = previous[start:start + 10]
            log(f"Detaching previous profiles {', '.join(batch)} from {arn}.")
            aws(
                "connect", "disassociate-security-profiles", "--instance-id", instance_id,
                "--entity-type", "AI_AGENT", "--entity-arn", arn,
                "--security-profiles", json.dumps([{"Id": item} for item in batch]),
            )
        verify(arn, lambda ids: ids == {admin_id}, "Admin-only assignment could not be verified")
    log(f"Admin security profile assigned to {len(targets)} custom AI-agent versions.")
    return len(targets)


def main():
    config = json.loads(os.environ["AI_AGENT_ADMIN_PROFILE_CONFIG"])

    def aws(service, operation, *arguments):
        # Use argv, not a shell, to preserve literal $LATEST version qualifiers.
        command = [
            "aws", service, operation, *arguments, "--region", config["region"],
            "--output", "json", "--no-cli-pager", "--no-cli-auto-prompt",
        ]
        result = subprocess.run(
            command, capture_output=True, text=True, encoding="utf-8",
            env={**os.environ, "AWS_PAGER": "", "AWS_CLI_AUTO_PROMPT": "off"},
        )
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip())
        return json.loads(result.stdout) if result.stdout.strip() else {}

    migrate(config, aws)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, RuntimeError, OSError) as error:
        print(f"AI-agent Admin security profile assignment failed: {error}", file=sys.stderr)
        sys.exit(1)
