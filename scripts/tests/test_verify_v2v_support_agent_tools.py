"""Check the published-agent contract used by the V2V apply gate."""
import json
import unittest
from copy import deepcopy

from scripts.verify_v2v_support_agent_tools import (
    MIRRORED,
    check_tools,
    load_expected,
    normalize_schema,
)

ASSISTANT_ID = "e36d6b86-c3f5-4d6d-b85b-e44f7e7ec04f"
ASSOCIATION_ID = "11111111-2222-3333-4444-555555555555"
EXPECTED = load_expected(ASSISTANT_ID, ASSOCIATION_ID)
GATEWAY_TOOL = {
    "toolName": "BTSGSD-V2V-US-snow-userlookup___UserLookUp___UserLookUp",
    "toolType": "MODEL_CONTEXT_PROTOCOL",
    "toolId": "gateway_example__BTSGSD-V2V-US-snow-userlookup___UserLookUp___UserLookUp",
}


def published(expected=EXPECTED):
    """An agent as get-ai-agent returns it after a correct apply."""
    return {
        "configuration": {
            "orchestrationAIAgentConfiguration": {
                "toolConfigurations": [deepcopy(GATEWAY_TOOL)]
                + [deepcopy(expected[name]) for name in MIRRORED]
            }
        }
    }


def tool(agent, name):
    tools = agent["configuration"]["orchestrationAIAgentConfiguration"]["toolConfigurations"]
    return next(item for item in tools if item["toolName"] == name)


class ExpectedTools(unittest.TestCase):
    def test_tokens_are_replaced_with_v2v_ids(self):
        overrides = {item["jsonPath"]: item["value"]["constant"] for item in EXPECTED["Retrieve"]["overrideInputValues"]}
        self.assertEqual(overrides["$.assistantId"]["value"], ASSISTANT_ID)
        self.assertEqual(
            json.loads(overrides["$.retrievalConfiguration.knowledgeSource.assistantAssociationIds"]["value"]),
            [ASSOCIATION_ID],
        )
        self.assertNotIn("__ASSISTANT_", json.dumps(EXPECTED))

    def test_no_dev_ids_remain(self):
        text = json.dumps(EXPECTED)
        for dev_id in ("bc274e3f-380d-45e7-968f-2d19f92acd74", "ede5afd1-18e1-4cd8-9cb0-4e78c31cd58a"):
            self.assertNotIn(dev_id, text)

    def test_schema_values_keep_their_types(self):
        schema = EXPECTED["Complete"]["inputSchema"]
        self.assertIs(schema["additionalProperties"], False)
        self.assertEqual(schema["properties"]["reason"]["minLength"], 8)


class PublishedToolChecks(unittest.TestCase):
    def test_matching_agent_passes(self):
        self.assertEqual(check_tools(published(), EXPECTED), [])

    def test_json_encoded_schemas_and_overrides_are_accepted(self):
        agent = published()
        for name in MIRRORED:
            item = tool(agent, name)
            for field in ("inputSchema", "outputSchema"):
                if field in item:
                    item[field] = json.dumps(item[field])
        retrieve = tool(agent, "Retrieve")
        for override in retrieve["overrideInputValues"]:
            constant = override["value"]["constant"]
            if constant["type"] == "JSON_STRING":
                constant["value"] = json.dumps(json.loads(constant["value"]), indent=2)
        retrieve["overrideInputValues"].reverse()
        self.assertEqual(check_tools(agent, EXPECTED), [])

    def test_required_and_enum_order_is_accepted(self):
        agent = published()
        for name in ("Complete", "Escalate"):
            schema = tool(agent, name)["inputSchema"]
            schema["required"].reverse()
            schema["properties"]["Intent"]["enum"].reverse()
        self.assertEqual(check_tools(agent, EXPECTED), [])

    def test_empty_annotations_equal_missing(self):
        agent = published()
        tool(agent, "Retrieve").pop("annotations", None)
        self.assertEqual(check_tools(agent, EXPECTED), [])

    def test_stringified_constraints_are_rejected(self):
        # What CloudFormation published: "false" and "8" instead of false and 8.
        for name in ("Complete", "Escalate"):
            for path, value in (
                (("additionalProperties",), "false"),
                (("properties", "reason", "minLength"), "8"),
            ):
                with self.subTest(tool=name, path=path):
                    agent = published()
                    parent = tool(agent, name)["inputSchema"]
                    for key in path[:-1]:
                        parent = parent[key]
                    parent[path[-1]] = value
                    errors = check_tools(agent, EXPECTED)
                    self.assertEqual(len(errors), 1)
                    self.assertTrue(errors[0].startswith(f"{name}: published inputSchema differs"))
                    self.assertIn(f"--- repository/{name}.inputSchema", errors[0])

    def test_each_compared_field_is_checked(self):
        changes = {
            "Retrieve": ("toolId", "description", "instruction", "outputSchema", "overrideInputValues", "title"),
            "Complete": ("toolId", "description", "instruction", "userInteractionConfiguration"),
            "Escalate": ("toolType", "inputSchema"),
        }
        for name, fields in changes.items():
            for field in fields:
                with self.subTest(tool=name, field=field):
                    agent = published()
                    item = tool(agent, name)
                    if field == "instruction":
                        item[field] = {"instruction": "Different instruction"}
                    elif field == "overrideInputValues":
                        item[field] = item[field][:1]
                    elif field == "userInteractionConfiguration":
                        item[field] = {"isUserConfirmationRequired": True}
                    elif field in ("inputSchema", "outputSchema"):
                        item[field] = {"type": "object"}
                    else:
                        item[field] = "changed"
                    errors = check_tools(agent, EXPECTED)
                    self.assertTrue(
                        any(error.startswith(f"{name}: published {field} differs") for error in errors),
                        errors,
                    )

    def test_dev_assistant_in_retrieve_is_rejected(self):
        dev = load_expected("bc274e3f-380d-45e7-968f-2d19f92acd74", "ede5afd1-18e1-4cd8-9cb0-4e78c31cd58a")
        errors = check_tools(published(dev), EXPECTED)
        self.assertEqual(len(errors), 1)
        self.assertTrue(errors[0].startswith("Retrieve: published overrideInputValues differs"))

    def test_missing_tool_is_rejected(self):
        agent = published()
        tools = agent["configuration"]["orchestrationAIAgentConfiguration"]["toolConfigurations"]
        tools.remove(tool(agent, "Retrieve"))
        errors = check_tools(agent, EXPECTED)
        self.assertIn("Retrieve: expected one tool, found 0", errors)

    def test_tool_order_is_checked(self):
        agent = published()
        tools = agent["configuration"]["orchestrationAIAgentConfiguration"]["toolConfigurations"]
        tools[-1], tools[-2] = tools[-2], tools[-1]
        errors = check_tools(agent, EXPECTED)
        self.assertEqual(len(errors), 1)
        self.assertTrue(errors[0].startswith("tool order"))


class Normalization(unittest.TestCase):
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
        for item in EXPECTED.values():
            normalize_schema(item["inputSchema"])
        self.assertEqual(EXPECTED, original)


if __name__ == "__main__":
    unittest.main()
