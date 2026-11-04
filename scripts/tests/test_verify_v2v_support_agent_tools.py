"""Check the published-agent contract used by the V2V apply gate."""

import json
import unittest
from copy import deepcopy

from scripts.verify_v2v_support_agent_tools import EXPECTED, check_tools, normalize_schema


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

    def test_required_and_enum_order_is_accepted_for_both_tools(self):
        agent = deepcopy(agent_with_tools())
        tools = agent["configuration"]["orchestrationAIAgentConfiguration"]["toolConfigurations"]
        for tool in tools:
            if tool["toolName"] in EXPECTED:
                schema = tool["inputSchema"]
                schema["required"].reverse()
                schema["properties"]["Intent"]["enum"].reverse()
                tool["inputSchema"] = json.dumps(schema)

        self.assertEqual(check_tools(agent), [])

    def test_nested_not_enum_order_is_accepted(self):
        schema = deepcopy(EXPECTED["Complete"])
        schema["properties"]["reason"]["not"]["enum"].reverse()
        self.assertEqual(check_tools(agent_with_tools(schema)), [])

    def test_real_schema_changes_are_rejected_with_matching_property_counts(self):
        for name, expected in EXPECTED.items():
            changes = [
                (("properties", "reason", "description"), "Different instruction"),
                (("properties", "reason", "type"), "number"),
                (("properties", "reason", "minLength"), 9),
                (("properties", "Intent", "enum"), expected["properties"]["Intent"]["enum"][:-1]),
                (("required",), expected["required"][:-1]),
                (("additionalProperties",), True),
            ]
            for path, replacement in changes:
                with self.subTest(tool=name, path=path):
                    schema = deepcopy(expected)
                    parent = schema
                    for key in path[:-1]:
                        parent = parent[key]
                    parent[path[-1]] = replacement
                    agent = deepcopy(agent_with_tools())
                    tools = agent["configuration"]["orchestrationAIAgentConfiguration"]["toolConfigurations"]
                    tool = next(tool for tool in tools if tool["toolName"] == name)
                    tool["inputSchema"] = schema

                    errors = check_tools(agent)

                    self.assertEqual(len(errors), 1)
                    self.assertTrue(errors[0].startswith(f"{name}: published input schema differs"))
                    self.assertIn(f"--- repository/{name}", errors[0])
                    self.assertIn(f"+++ published/{name}", errors[0])

    def test_difference_includes_changed_constraint_values(self):
        schema = deepcopy(EXPECTED["Complete"])
        schema["properties"]["reason"]["minLength"] = 9
        error = check_tools(agent_with_tools(schema))[0]
        self.assertIn('-      "minLength": 8,', error)
        self.assertIn('+      "minLength": 9,', error)

    def test_literal_values_are_not_normalized_as_schemas(self):
        original = {
            "default": {"required": ["b", "a"]},
            "const": {"enum": ["b", "a"]},
            "enum": [{"required": ["b", "a"]}],
        }
        self.assertEqual(normalize_schema(original), original)

    def test_ordered_schema_arrays_remain_distinct(self):
        first = {"prefixItems": [{"type": "string"}, {"type": "number"}]}
        second = {"prefixItems": list(reversed(first["prefixItems"]))}
        self.assertNotEqual(normalize_schema(first), normalize_schema(second))

    def test_normalization_does_not_mutate_repository_schemas(self):
        original = deepcopy(EXPECTED)
        for schema in EXPECTED.values():
            normalize_schema(schema)
        self.assertEqual(EXPECTED, original)

    def test_blank_complete_schema_is_rejected(self):
        errors = check_tools(agent_with_tools({}))
        self.assertTrue(any(error.startswith("Complete: published input schema differs") for error in errors))

    def test_missing_retrieve_is_rejected(self):
        agent = agent_with_tools()
        agent["configuration"]["orchestrationAIAgentConfiguration"]["toolConfigurations"].pop(0)
        self.assertIn("Retrieve: expected one tool, found 0", check_tools(agent))


if __name__ == "__main__":
    unittest.main()
