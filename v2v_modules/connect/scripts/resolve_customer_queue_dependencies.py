"""Resolve exported customer-queue dependencies using read-only AWS CLI calls.

Implements the Terraform external data source's string-map JSON protocol.
AWS CLI uses the same ambient profile/OIDC credentials as the pipeline.
The source file is never changed and no AWS resources are created.
"""

import json
import os
import subprocess
import sys


RESOURCE_TYPES = {
    "PromptId": ("list-prompts", "PromptSummaryList", "Arn"),
    "DataTableId": ("list-data-tables", "DataTableSummaryList", "Id"),
    "FlowModuleId": (
        "list-contact-flow-modules", "ContactFlowModulesSummaryList", "Id"
    ),
}


def list_resources(operation, result_key, query):
    command = [
        "aws", "connect", operation,
        "--instance-id", query["instance_id"],
        "--region", query["region"],
        "--output", "json", "--no-cli-pager",
        "--cli-connect-timeout", "10", "--cli-read-timeout", "20",
    ]
    environment = dict(os.environ)
    environment.setdefault("AWS_MAX_ATTEMPTS", "2")
    try:
        response = subprocess.run(
            command, capture_output=True, text=True, timeout=60, env=environment
        )
    except FileNotFoundError as error:
        raise RuntimeError("AWS CLI is not installed or is not on PATH.") from error
    if response.returncode:
        if operation == "list-data-tables" and "Invalid choice" in response.stderr:
            raise RuntimeError(
                "AWS CLI does not support connect list-data-tables. "
                "Upgrade AWS CLI v2 on the pipeline agent."
            )
        raise RuntimeError(
            f"Read-only dependency lookup {operation} failed: "
            f"{response.stderr.strip()}"
        )
    result = json.loads(response.stdout)
    if result_key not in result:
        raise RuntimeError(f"{operation} did not return {result_key}.")
    return result[result_key]


def resolve(query, inventory_loader=list_resources):
    flow = json.loads(query["content"])
    overrides = json.loads(query.get("name_overrides", "{}"))
    if not isinstance(overrides, dict):
        raise ValueError("name_overrides must be a JSON object.")
    actions = flow.get("Actions")
    if not isinstance(actions, list) or not actions:
        raise ValueError("The customer-queue export is missing Actions.")
    metadata = flow.get("Metadata", {}).get("ActionMetadata", {})
    inventory = {}
    problems = []

    for action in actions:
        parameters = action.get("Parameters", {})
        action_metadata = metadata.get(action["Identifier"], {})
        for parameter, specification in RESOURCE_TYPES.items():
            if parameter not in parameters:
                continue
            exported_name = (
                action_metadata.get("parameters", {})
                .get(parameter, {}).get("displayName")
            )
            if not exported_name:
                problems.append(
                    f"{action['Identifier']}: {parameter} has no exported displayName."
                )
                continue
            target_name = overrides.get(exported_name, exported_name)
            operation, result_key, value_key = specification
            if parameter not in inventory:
                inventory[parameter] = inventory_loader(operation, result_key, query)
            matches = [
                item for item in inventory[parameter]
                if item.get("Name") == target_name
                and item.get("State") != "ARCHIVED"
            ]
            if len(matches) != 1:
                available = sorted(
                    item["Name"] for item in inventory[parameter]
                    if item.get("Name") and item.get("State") != "ARCHIVED"
                )
                problems.append(
                    f"{parameter}: expected one active resource named {target_name!r}, "
                    f"found {len(matches)} in {query['instance_id']}. "
                    f"Available names: {', '.join(available) or '(none)'}."
                )
                continue
            target = matches[0]
            if not target.get("Arn", "").startswith(query["instance_arn"] + "/"):
                problems.append(
                    f"{parameter}: {target_name!r} is outside the target instance."
                )
                continue
            value = target.get(value_key)
            if not value:
                problems.append(f"{parameter}: {target_name!r} has no {value_key}.")
                continue
            if parameter == "FlowModuleId":
                # Preserve the exported module alias/version, including $LATEST.
                _, separator, suffix = str(parameters[parameter]).partition(":")
                if separator:
                    value += separator + suffix
            parameters[parameter] = value
            action_metadata["parameters"][parameter]["displayName"] = target_name
            if parameter == "PromptId" and "promptName" in action_metadata:
                action_metadata["promptName"] = target_name
            if parameter == "FlowModuleId" and "contactFlowModuleName" in action_metadata:
                action_metadata["contactFlowModuleName"] = target_name

    if problems:
        raise ValueError(
            "Customer-queue dependencies are unresolved:\n- "
            + "\n- ".join(problems)
            + "\nCreate/import the missing resources or set "
            "connect_customer_queue_dependency_names to their actual Dev names."
        )
    return {"content": json.dumps(flow, ensure_ascii=False, separators=(",", ":"))}


def main():
    try:
        result = resolve(json.load(sys.stdin))
        json.dump(result, sys.stdout)
        sys.stdout.write("\n")
    except (ValueError, KeyError, OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
