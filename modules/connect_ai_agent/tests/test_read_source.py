import copy
import importlib.util
import json
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "read_source", Path(__file__).resolve().parents[1] / "read_source.py"
)
source_reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source_reader)


class SourceDiscoveryTest(unittest.TestCase):
    def setUp(self):
        self.query = {
            "assistant_id": "00000000-0000-0000-0000-000000000001",
            "connect_instance_arn": "arn:aws:connect:us-east-1:123456789012:instance/instance-id",
            "account_id": "123456789012",
            "region": "us-east-1",
            "aws_profile": "",
            "source_name": "SelfServiceOrchestratorVoice",
            "model_id": "global.anthropic.claude-sonnet-5",
        }
        self.configuration = {
            "orchestrationAIPromptId": "source-prompt:1",
            "orchestrationAIGuardrailId": "source-guardrail:1",
            "locale": "en_US",
            "toolConfigurations": [{
                "toolName": "Retrieve",
                "toolType": "MODEL_CONTEXT_PROTOCOL",
                "toolId": "actual-source-tool",
                "inputSchema": {
                    "type": "object",
                    "properties": {"customerId": {"type": "string"}},
                },
                "outputSchema": {"properties": {"answerText": {"type": "string"}}},
                "annotations": {"readOnlyHint": True},
                "overrideInputValues": [{
                    "jsonPath": "$.assistantId",
                    "value": {"constant": {"type": "STRING", "value": self.query["assistant_id"]}},
                }],
            }],
        }
        self.prompt_text = "system: Voice protocol\nmessages:\n- '{{$.conversationHistory}}'\n"
        self.responses = {
            "get-caller-identity": {"Account": self.query["account_id"]},
            "get-assistant": {"assistant": {"assistantArn": "arn:assistant"}},
            "list-integration-associations": {"IntegrationAssociationSummaryList": [{
                "IntegrationType": "WISDOM_ASSISTANT", "IntegrationArn": "arn:assistant",
            }]},
            "list-models": {"modelSummaries": [{
                "modelId": self.query["model_id"], "crossRegionStatus": "GLOBAL",
                "modelLifecycle": "ACTIVE", "supportedAIPromptTypes": ["ORCHESTRATION"],
            }]},
            "list-ai-agents": {"aiAgentSummaries": [{
                "name": "SelfServiceOrchestratorVoice", "type": "ORCHESTRATION", "aiAgentId": "source-agent",
            }]},
            "get-ai-agent": {"aiAgent": {
                "aiAgentId": "source-agent",
                "configuration": {"orchestrationAIAgentConfiguration": self.configuration},
            }},
            "get-ai-prompt": {"aiPrompt": {
                "type": "ORCHESTRATION", "apiFormat": "MESSAGES",
                "templateConfiguration": {"textFullAIPromptEditTemplateConfiguration": {
                    "text": self.prompt_text,
                }},
            }},
        }
        self.calls = []

    def aws(self, service, operation, *arguments):
        self.calls.append((service, operation, arguments))
        return copy.deepcopy(self.responses[operation])

    def discover(self):
        return source_reader.discover(self.query, self.aws)

    def test_copies_tools_guardrail_and_prompt_without_changing_json_keys(self):
        result = self.discover()
        configuration = json.loads(result["configuration"])
        tool = configuration["ToolConfigurations"][0]
        self.assertEqual(configuration["OrchestrationAIGuardrailId"], "source-guardrail:1")
        self.assertEqual(tool["ToolId"], "actual-source-tool")
        self.assertEqual(tool["InputSchema"]["properties"]["customerId"]["type"], "string")
        self.assertIn("answerText", tool["OutputSchema"]["properties"])
        self.assertTrue(tool["Annotations"]["readOnlyHint"])
        self.assertEqual(tool["OverrideInputValues"][0]["Value"]["Constant"]["Value"], self.query["assistant_id"])
        self.assertEqual(result["prompt_text"], self.prompt_text)
        self.assertTrue(all(isinstance(value, str) for value in result.values()))
        self.assertTrue(all(operation.startswith(("get-", "list-")) for _, operation, _ in self.calls))

    def test_account_mismatch_stops_discovery(self):
        self.responses["get-caller-identity"]["Account"] = "000000000000"
        with self.assertRaisesRegex(ValueError, "same AWS account"):
            self.discover()
        self.assertEqual(len(self.calls), 1)

    def test_instance_region_mismatch_stops_discovery(self):
        self.query["connect_instance_arn"] = self.query["connect_instance_arn"].replace("us-east-1", "us-west-2")
        with self.assertRaisesRegex(ValueError, "provider account and region"):
            self.discover()

    def test_requires_matching_assistant_association(self):
        self.responses["list-integration-associations"]["IntegrationAssociationSummaryList"] = []
        with self.assertRaisesRegex(ValueError, "not associated"):
            self.discover()

    def test_rejects_unavailable_legacy_regional_and_wrong_type_models(self):
        original = self.responses["list-models"]["modelSummaries"][0]
        for key, value in (
            ("modelId", "another-model"), ("crossRegionStatus", "REGIONAL"),
            ("modelLifecycle", "LEGACY"), ("supportedAIPromptTypes", ["ANSWER_GENERATION"]),
        ):
            with self.subTest(key=key):
                self.responses["list-models"]["modelSummaries"] = [{**original, key: value}]
                with self.assertRaisesRegex(ValueError, "model is unavailable"):
                    self.discover()

    def test_requires_one_matching_source(self):
        agent = self.responses["list-ai-agents"]["aiAgentSummaries"][0]
        for summaries in ([], [agent, agent], [{**agent, "type": "SELF_SERVICE"}]):
            with self.subTest(summaries=summaries):
                self.responses["list-ai-agents"]["aiAgentSummaries"] = summaries
                with self.assertRaisesRegex(ValueError, "exactly one"):
                    self.discover()

    def test_accepts_system_prefixed_source_name(self):
        self.responses["list-ai-agents"]["aiAgentSummaries"][0]["name"] = "system:" + self.query["source_name"]
        self.assertEqual(self.discover()["source_agent_id"], "source-agent")

    def test_rejects_prompt_name_as_source_agent_name(self):
        self.query["source_name"] = "SelfServiceOrchestrationVoice"
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.discover()
        self.assertFalse(any(operation == "get-ai-agent" for _, operation, _ in self.calls))

    def test_rejects_unsupported_source_fields_instead_of_losing_configuration(self):
        self.configuration["multiAgentConfigurations"] = [{"delegateAgentConfiguration": {}}]
        with self.assertRaisesRegex(ValueError, "unsupported by CloudFormation"):
            self.discover()

    def test_rejects_incompatible_prompt_format(self):
        self.responses["get-ai-prompt"]["aiPrompt"]["apiFormat"] = "TEXT_COMPLETIONS"
        with self.assertRaisesRegex(ValueError, "MESSAGES prompt"):
            self.discover()


if __name__ == "__main__":
    unittest.main()
