"""Read-only AWS discovery for Terraform's external data source."""

import json
import os
import subprocess
import sys


ORCHESTRATION_FIELDS = {
    "connectInstanceArn", "locale", "orchestrationAIGuardrailId",
    "orchestrationAIPromptId", "toolConfigurations",
}
JSON_FIELDS = {"inputSchema", "outputSchema", "annotations"}


def to_cloudformation(value):
    if isinstance(value, list):
        return [to_cloudformation(item) for item in value]
    if isinstance(value, dict):
        # Document fields are JSON schemas/annotations, not CloudFormation properties.
        return {
            key[0].upper() + key[1:]: (
                item if key in JSON_FIELDS else to_cloudformation(item)
            )
            for key, item in value.items()
        }
    return value


def discover(query, aws):
    identity = aws("sts", "get-caller-identity")
    if identity["Account"] != query["account_id"]:
        raise ValueError("AWS CLI and Terraform must use the same AWS account.")

    instance_parts = query["connect_instance_arn"].split(":", 5)
    if (
        len(instance_parts) != 6
        or instance_parts[2] != "connect"
        or instance_parts[3] != query["region"]
        or instance_parts[4] != query["account_id"]
        or not instance_parts[5].startswith("instance/")
    ):
        raise ValueError("Connect instance ARN must match the provider account and region.")

    assistant = aws(
        "qconnect", "get-assistant", "--assistant-id", query["assistant_id"]
    )["assistant"]
    integrations = aws(
        "connect", "list-integration-associations",
        "--instance-id", instance_parts[5].split("/", 1)[1],
        "--integration-type", "WISDOM_ASSISTANT",
    )["IntegrationAssociationSummaryList"]
    if not any(
        item["IntegrationType"] == "WISDOM_ASSISTANT"
        and item["IntegrationArn"] == assistant["assistantArn"]
        for item in integrations
    ):
        raise ValueError("The assistant is not associated with this Connect instance.")

    models = aws(
        "qconnect", "list-models", "--assistant-id", query["assistant_id"],
        "--ai-prompt-type", "ORCHESTRATION", "--model-lifecycle", "ACTIVE",
    )["modelSummaries"]
    if not any(
        model["modelId"] == query["model_id"]
        and model.get("crossRegionStatus") == "GLOBAL"
        and "ORCHESTRATION" in model.get("supportedAIPromptTypes", [])
        and model.get("modelLifecycle") == "ACTIVE"
        for model in models
    ):
        raise ValueError(
            "Requested active global orchestration model is unavailable: "
            + query["model_id"]
        )

    agents = aws(
        "qconnect", "list-ai-agents", "--assistant-id", query["assistant_id"],
        "--origin", "SYSTEM",
    )["aiAgentSummaries"]
    matches = [
        agent for agent in agents
        if agent["name"] in (query["source_name"], "system:" + query["source_name"])
        and agent["type"] == "ORCHESTRATION"
    ]
    if len(matches) != 1:
        raise ValueError("Expected exactly one system orchestration agent: " + query["source_name"])

    source = aws(
        "qconnect", "get-ai-agent", "--assistant-id", query["assistant_id"],
        "--ai-agent-id", matches[0]["aiAgentId"],
    )["aiAgent"]
    configuration = source["configuration"]["orchestrationAIAgentConfiguration"]
    unsupported = [
        key for key in configuration
        if key not in ORCHESTRATION_FIELDS and configuration[key]
    ]
    if unsupported:
        raise ValueError("Source fields unsupported by CloudFormation: " + ", ".join(unsupported))

    prompt = aws(
        "qconnect", "get-ai-prompt", "--assistant-id", query["assistant_id"],
        "--ai-prompt-id", configuration["orchestrationAIPromptId"],
    )["aiPrompt"]
    if prompt["type"] != "ORCHESTRATION" or prompt["apiFormat"] not in (
        "MESSAGES", "ANTHROPIC_CLAUDE_MESSAGES",
    ):
        raise ValueError("The source must use an orchestration MESSAGES prompt.")

    return {
        "source_agent_id": source["aiAgentId"],
        "configuration": json.dumps(to_cloudformation({
            key: value for key, value in configuration.items()
            if key in ORCHESTRATION_FIELDS
        })),
        "prompt_text": prompt["templateConfiguration"][
            "textFullAIPromptEditTemplateConfiguration"
        ]["text"],
    }


def main():
    query = json.load(sys.stdin)

    def aws(service, operation, *arguments):
        command = [
            "aws", service, operation, *arguments,
            "--region", query["region"], "--output", "json",
            "--no-cli-pager", "--no-cli-auto-prompt",
        ]
        if query["aws_profile"]:
            command.extend(["--profile", query["aws_profile"]])
        result = subprocess.run(
            command, capture_output=True, text=True, encoding="utf-8",
            env={**os.environ, "AWS_PAGER": "", "AWS_CLI_AUTO_PROMPT": "off"},
        )
        if result.returncode:
            raise RuntimeError(result.stderr.strip())
        return json.loads(result.stdout)

    print(json.dumps(discover(query, aws)))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
