"""Fail a V2V SupportAgent apply if its published tools lost their schemas."""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path


ASSETS = Path(__file__).resolve().parents[1] / "v2v_modules" / "connect_ai_agent" / "assets"
EXPECTED = {
    "Complete": json.loads((ASSETS / "complete-input-schema.json").read_text(encoding="utf-8")),
    "Escalate": json.loads((ASSETS / "escalate-input-schema.json").read_text(encoding="utf-8")),
}


def aws_json(region, *arguments):
    result = subprocess.run(
        ["aws", *arguments, "--region", region, "--output", "json", "--no-cli-pager"],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def schema_object(value):
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value
    return value


def check_tools(agent):
    configuration = agent.get("configuration", {}).get("orchestrationAIAgentConfiguration", {})
    tools = configuration.get("toolConfigurations", [])
    errors = []

    for name in ("Retrieve", "Escalate", "Complete"):
        matches = [tool for tool in tools if tool.get("toolName") == name]
        if len(matches) != 1:
            errors.append(f"{name}: expected one tool, found {len(matches)}")
            continue

        tool = matches[0]
        expected_type = "RETURN_TO_CONTROL" if name in EXPECTED else "MODEL_CONTEXT_PROTOCOL"
        if tool.get("toolType") != expected_type:
            errors.append(f"{name}: expected type {expected_type}, got {tool.get('toolType')!r}")
        if not (tool.get("instruction") or {}).get("instruction", "").strip():
            errors.append(f"{name}: instruction is blank")
        if name in EXPECTED and schema_object(tool.get("inputSchema")) != EXPECTED[name]:
            actual = schema_object(tool.get("inputSchema"))
            actual_count = len(actual.get("properties", {})) if isinstance(actual, dict) else 0
            errors.append(
                f"{name}: published input schema differs from the repository "
                f"({actual_count} properties; expected {len(EXPECTED[name]['properties'])})"
            )

    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--region", required=True)
    parser.add_argument("--stack-name", required=True)
    args = parser.parse_args()

    stack = aws_json(args.region, "cloudformation", "describe-stacks", "--stack-name", args.stack_name)["Stacks"][0]
    outputs = {item["OutputKey"]: item["OutputValue"] for item in stack.get("Outputs", [])}
    assistant_id = outputs["AssistantId"]
    version_id = outputs["AgentVersionId"]

    for attempt in range(6):
        agent = aws_json(
            args.region, "qconnect", "get-ai-agent", "--assistant-id", assistant_id,
            "--ai-agent-id", version_id,
        )["aiAgent"]
        errors = check_tools(agent)
        if not errors:
            print(f"Verified published SupportAgent {version_id}: Retrieve, Escalate and Complete; both input schemas match.")
            return 0
        if attempt < 5:
            time.sleep(5)

    print(f"Published SupportAgent {version_id} is missing its requested tool configuration:", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    print("Check this stack's SupportAgent and SupportAgentVersion events, then compare the saved CloudFormation template with get-ai-agent.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        print(
            f"Unable to verify the published V2V SupportAgent: {error.stderr.strip() or error}",
            file=sys.stderr,
        )
        sys.exit(1)
    except (KeyError, IndexError) as error:
        print(f"Unable to verify the published V2V SupportAgent: {error}", file=sys.stderr)
        sys.exit(1)
