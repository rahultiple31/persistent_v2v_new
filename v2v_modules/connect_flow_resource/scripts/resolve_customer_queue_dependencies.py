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
    # "lexv2-models <operation>[:<bot id>]" reads Lex; anything else is a
    # Connect list call scoped to the target instance.
    if operation.startswith("lexv2-models "):
        lex_operation, _, bot_id = operation.split(" ", 1)[1].partition(":")
        command = ["aws", "lexv2-models", lex_operation]
        if bot_id:
            command += ["--bot-id", bot_id]
    else:
        command = ["aws", "connect", operation, "--instance-id", query["instance_id"]]
        if operation == "list-bots":
            command += ["--lex-version", "V2"]
    command += [
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

    # Resolve Lex V2 bot aliases by the bot and alias names the export shows,
    # mapped through name_overrides, and require the alias to be associated
    # with the target instance. The labels shown in the designer follow.
    account = query["instance_arn"].split(":")[4]
    for action in actions:
        lex = action.get("Parameters", {}).get("LexV2Bot")
        # Dynamic aliases ($.Attributes...) are left to the flow.
        if not isinstance(lex, dict) or not str(lex.get("AliasArn", "")).startswith("arn:"):
            continue
        action_metadata = metadata.get(action["Identifier"], {})
        shown = action_metadata.get("parameters", {}).get("LexV2Bot", {}).get("AliasArn", {})
        if not isinstance(shown, dict) or not shown.get("lexV2BotName") or not shown.get("displayName"):
            problems.append(
                f"{action['Identifier']}: LexV2Bot has no exported bot and alias names."
            )
            continue
        bot_name = overrides.get(shown["lexV2BotName"], shown["lexV2BotName"])
        alias_name = overrides.get(shown["displayName"], shown["displayName"])
        if "LexBots" not in inventory:
            inventory["LexBots"] = inventory_loader("lexv2-models list-bots", "botSummaries", query)
        bots = [item for item in inventory["LexBots"] if item.get("botName") == bot_name]
        if len(bots) != 1:
            problems.append(
                f"LexV2Bot: expected one Lex bot named {bot_name!r}, found {len(bots)}."
            )
            continue
        bot_id = bots[0]["botId"]
        alias_key = f"LexAliases:{bot_id}"
        if alias_key not in inventory:
            inventory[alias_key] = inventory_loader(
                f"lexv2-models list-bot-aliases:{bot_id}", "botAliasSummaries", query
            )
        aliases = [item for item in inventory[alias_key] if item.get("botAliasName") == alias_name]
        if len(aliases) != 1:
            problems.append(
                f"LexV2Bot: expected one alias named {alias_name!r} on {bot_name!r}, "
                f"found {len(aliases)}."
            )
            continue
        alias_arn = (
            f"arn:aws:lex:{query['region']}:{account}:bot-alias/"
            f"{bot_id}/{aliases[0]['botAliasId']}"
        )
        if "LexAssociations" not in inventory:
            inventory["LexAssociations"] = {
                item.get("LexV2Bot", {}).get("AliasArn")
                for item in inventory_loader("list-bots", "LexBots", query)
            }
        if alias_arn not in inventory["LexAssociations"]:
            problems.append(
                f"LexV2Bot: {bot_name!r} alias {alias_name!r} is not associated "
                "with the target instance."
            )
            continue
        lex["AliasArn"] = alias_arn
        shown["displayName"] = alias_name
        shown["lexV2BotName"] = bot_name
        if "lexV2BotName" in action_metadata:
            action_metadata["lexV2BotName"] = bot_name
        if "lexV2BotAliasName" in action_metadata:
            action_metadata["lexV2BotAliasName"] = alias_name

    # Show the function actually invoked, not the exported function's name.
    for action in actions:
        function_arn = action.get("Parameters", {}).get("LambdaFunctionARN", "")
        shown = (
            metadata.get(action["Identifier"], {})
            .get("parameters", {}).get("LambdaFunctionARN")
        )
        if ":function:" in function_arn and isinstance(shown, dict) and "displayName" in shown:
            shown["displayName"] = function_arn.split(":")[6]

    # Resolve callback queue attributes copied from another Connect instance.
    for action in actions:
        attributes = action.get("Parameters", {}).get("Attributes", {})
        exported_arn = attributes.get("callbackOutboundQueue")
        if not exported_arn:
            continue

        target_name = overrides.get(exported_arn)
        if not target_name:
            if exported_arn.startswith(query["instance_arn"] + "/queue/"):
                continue
            problems.append(
                f"{action['Identifier']}: callbackOutboundQueue requires "
                "a target queue-name mapping."
            )
            continue

        if "CallbackQueue" not in inventory:
            inventory["CallbackQueue"] = inventory_loader(
                "list-queues", "QueueSummaryList", query
            )
        matches = [
            item for item in inventory["CallbackQueue"]
            if item.get("Name") == target_name
        ]
        if len(matches) != 1:
            problems.append(
                f"callbackOutboundQueue: expected one queue named "
                f"{target_name!r}, found {len(matches)}."
            )
            continue

        target_arn = matches[0].get("Arn", "")
        if not target_arn.startswith(query["instance_arn"] + "/queue/"):
            problems.append(
                f"callbackOutboundQueue: {target_name!r} is outside "
                "the target instance."
            )
            continue
        attributes["callbackOutboundQueue"] = target_arn

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
