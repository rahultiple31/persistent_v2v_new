"""Fail a V2V SupportAgent apply if its published Retrieve, Complete and
Escalate tools differ from the dev copies in v2v_modules/connect_ai_agent/assets/tools.

The agent is read from `terraform output -json btsgsd_support_agent` in the
current directory unless --assistant-id and --agent-version-id are given.
"""
import argparse
import json
import subprocess
import sys
import time
from difflib import unified_diff
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1] / "v2v_modules" / "connect_ai_agent" / "assets" / "tools"
MIRRORED = ("Retrieve", "Complete", "Escalate")
ASSISTANT_TOKEN = "__ASSISTANT_ID__"
ASSOCIATION_TOKEN = "__ASSISTANT_ASSOCIATION_IDS__"
# Fields compared one by one; the instruction, schemas and overrides are the
# parts CloudFormation used to drop or stringify.
FIELDS = (
    "toolType",
    "toolId",
    "title",
    "description",
    "instruction",
    "inputSchema",
    "outputSchema",
    "annotations",
    "overrideInputValues",
    "userInteractionConfiguration",
)
SCHEMA_FIELDS = ("inputSchema", "outputSchema", "annotations")


def load_expected(assistant_id, association_id):
    """Repository tool definitions with the V2V assistant and association filled in."""
    expected = {}
    for name in MIRRORED:
        tool = json.loads((TOOLS / f"{name.lower()}.json").read_text(encoding="utf-8"))
        for override in tool.get("overrideInputValues", []):
            constant = override["value"]["constant"]
            if constant["value"] == ASSISTANT_TOKEN:
                constant["value"] = assistant_id
            elif constant["value"] == ASSOCIATION_TOKEN:
                constant["value"] = json.dumps([association_id])
        expected[name] = tool
    return expected


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


def normalize_schema(value):
    if not isinstance(value, dict):
        return value
    result = dict(value)
    # These keyword arrays describe sets; preserve all their values.
    for keyword in ("required", "enum"):
        if isinstance(result.get(keyword), list):
            result[keyword] = sorted(
                result[keyword],
                key=lambda item: json.dumps(item, sort_keys=True),
            )
    # Visit schema positions without changing literal default/enum values.
    for keyword in (
        "properties",
        "patternProperties",
        "$defs",
        "definitions",
        "dependentSchemas",
    ):
        if isinstance(result.get(keyword), dict):
            result[keyword] = {
                name: normalize_schema(schema)
                for name, schema in result[keyword].items()
            }
    for keyword in (
        "not",
        "items",
        "additionalProperties",
        "additionalItems",
        "contains",
        "propertyNames",
        "if",
        "then",
        "else",
        "unevaluatedProperties",
        "unevaluatedItems",
    ):
        if isinstance(result.get(keyword), dict):
            result[keyword] = normalize_schema(result[keyword])
    for keyword in ("allOf", "anyOf", "oneOf", "prefixItems", "items"):
        if isinstance(result.get(keyword), list):
            result[keyword] = [
                normalize_schema(schema) for schema in result[keyword]
            ]
    return result


def normalize_overrides(value):
    """Overrides keyed by jsonPath; JSON_STRING values compare as parsed JSON."""
    result = {}
    for override in value or []:
        constant = (override.get("value") or {}).get("constant") or {}
        content = constant.get("value")
        if constant.get("type") == "JSON_STRING":
            content = schema_object(content)
        result[override.get("jsonPath")] = {"type": constant.get("type"), "value": content}
    return result


def normalize_field(field, value):
    if field in SCHEMA_FIELDS:
        value = normalize_schema(schema_object(value))
    elif field == "overrideInputValues":
        value = normalize_overrides(value)
    elif field == "instruction" and isinstance(value, dict):
        value = {
            "instruction": value.get("instruction"),
            "examples": list(value.get("examples") or []),
        }
    # An empty object or list is what the API returns for an unset field.
    return None if value in ({}, [], "") else value


def describe(field, name, expected, actual):
    difference = "\n".join(
        unified_diff(
            json.dumps(expected, indent=2, sort_keys=True).splitlines(),
            json.dumps(actual, indent=2, sort_keys=True).splitlines(),
            fromfile=f"repository/{name}.{field}",
            tofile=f"published/{name}.{field}",
            lineterm="",
        )
    )
    return f"{name}: published {field} differs from the repository\n{difference}"


def check_tools(agent, expected):
    configuration = agent.get("configuration", {}).get("orchestrationAIAgentConfiguration", {})
    tools = configuration.get("toolConfigurations", [])
    errors = []
    names = [tool.get("toolName") for tool in tools]
    # Dev order: the gateway tools, then Retrieve, Complete and Escalate.
    if names[-len(MIRRORED):] != list(MIRRORED):
        errors.append(f"tool order: expected the list to end with {list(MIRRORED)}, got {names}")
    for name in MIRRORED:
        matches = [tool for tool in tools if tool.get("toolName") == name]
        if len(matches) != 1:
            errors.append(f"{name}: expected one tool, found {len(matches)}")
            continue
        for field in FIELDS:
            want = normalize_field(field, expected[name].get(field))
            got = normalize_field(field, matches[0].get(field))
            if want != got:
                errors.append(describe(field, name, want, got))
    return errors


def deployment_from_terraform():
    result = subprocess.run(
        ["terraform", "output", "-json", "btsgsd_support_agent"],
        check=True,
        capture_output=True,
        text=True,
    )
    deployment = json.loads(result.stdout)
    if not deployment:
        raise KeyError("btsgsd_support_agent output is empty; is the SupportAgent enabled in this state?")
    return deployment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--region", required=True)
    parser.add_argument("--assistant-id")
    parser.add_argument("--agent-version-id", help="agentId:version, as returned by AgentVersionId")
    parser.add_argument("--association-id", help="Knowledge-base assistant association Retrieve must pin")
    args = parser.parse_args()

    if args.assistant_id and args.agent_version_id and args.association_id:
        assistant_id, version_id, association_id = args.assistant_id, args.agent_version_id, args.association_id
        knowledge_base_id = None
    else:
        deployment = deployment_from_terraform()
        assistant_id = deployment["AssistantId"]
        version_id = deployment["AgentVersionId"]
        association_id = deployment["KnowledgeBaseAssociationId"]
        knowledge_base_id = deployment.get("KnowledgeBaseId")

    if knowledge_base_id:
        association = aws_json(
            args.region, "qconnect", "get-assistant-association",
            "--assistant-id", assistant_id, "--assistant-association-id", association_id,
        )["assistantAssociation"]
        linked = (association.get("associationData") or {}).get("knowledgeBaseAssociation", {}).get("knowledgeBaseId")
        if linked != knowledge_base_id:
            print(f"Association {association_id} links knowledge base {linked!r}, expected {knowledge_base_id}.", file=sys.stderr)
            return 1

    expected = load_expected(assistant_id, association_id)
    for attempt in range(6):
        agent = aws_json(
            args.region, "qconnect", "get-ai-agent", "--assistant-id", assistant_id,
            "--ai-agent-id", version_id,
        )["aiAgent"]
        errors = check_tools(agent, expected)
        if not errors:
            print(
                f"Verified published SupportAgent {version_id}: Retrieve, Complete and Escalate "
                "match the dev copies, and Retrieve pins this assistant and its knowledge-base association."
            )
            return 0
        if attempt < 5:
            time.sleep(5)
    print(f"Published SupportAgent {version_id} differs from assets/tools:", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    print("Compare `aws qconnect get-ai-agent` with v2v_modules/connect_ai_agent/assets/tools.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as error:
        print(
            f"Unable to verify the published V2V SupportAgent: {(error.stderr or '').strip() or error}",
            file=sys.stderr,
        )
        sys.exit(1)
    except (KeyError, IndexError, json.JSONDecodeError) as error:
        print(f"Unable to verify the published V2V SupportAgent: {error}", file=sys.stderr)
        sys.exit(1)
