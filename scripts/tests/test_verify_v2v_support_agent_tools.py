"""Check the published-agent contract used by the V2V apply gate."""

import json
import unittest

from scripts.verify_v2v_support_agent_tools import EXPECTED, check_tools


def agent_with_tools(complete_schema=None):
    return {
        "configuration": {
            "orchestrationAIAgentConfiguration": {
                "toolConfigurations": [
                    {
                        "toolName": "Retrieve",
                        "toolType": "MODEL_CONTEXT_PROTOCOL",
                        "instruction": {"instruction": "Retrieve support information."},
                    },
                    {
                        "toolName": "Complete",
                        "toolType": "RETURN_TO_CONTROL",
                        "instruction": {"instruction": "Close after the spoken message."},
                        "inputSchema": EXPECTED["Complete"] if complete_schema is None else complete_schema,
                    },
                    {
                        "toolName": "Escalate",
                        "toolType": "RETURN_TO_CONTROL",
                        "instruction": {"instruction": "Transfer after the spoken message."},
                        "inputSchema": EXPECTED["Escalate"],
                    },
                ]
            }
        }
    }


class PublishedToolChecks(unittest.TestCase):
    def test_published_tool_schemas_match(self):
        self.assertEqual(check_tools(agent_with_tools()), [])

    def test_json_encoded_schema_is_accepted(self):
        self.assertEqual(check_tools(agent_with_tools(json.dumps(EXPECTED["Complete"]))), [])

    def test_blank_complete_schema_is_rejected(self):
        errors = check_tools(agent_with_tools({}))
        self.assertTrue(any(error.startswith("Complete: published input schema differs") for error in errors))

    def test_missing_retrieve_is_rejected(self):
        agent = agent_with_tools()
        agent["configuration"]["orchestrationAIAgentConfiguration"]["toolConfigurations"].pop(0)
        self.assertIn("Retrieve: expected one tool, found 0", check_tools(agent))


if __name__ == "__main__":
    unittest.main()
