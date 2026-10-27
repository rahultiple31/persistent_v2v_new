import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch


MODULE_DIR = Path(__file__).resolve().parents[1]
REPO_DIR = MODULE_DIR.parents[1]
SPEC = importlib.util.spec_from_file_location(
    "resolver", MODULE_DIR / "scripts" / "resolve_customer_queue_dependencies.py"
)
resolver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(resolver)

INSTANCE = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
INSTANCE_ARN = f"arn:aws:connect:us-east-1:518902362956:instance/{INSTANCE}"
MODULE_NAME = "VMX3_Main_VM_Module_abbvie-sd-contactcenter-dev-us"


class DependencyResolutionTests(unittest.TestCase):
    def setUp(self):
        self.source = (
            REPO_DIR / "v2v_modules/customer_queue_flow/assets"
            / "BTSGSD_Abbvie_CustomerQueueFlow.json"
        ).read_text(encoding="utf-8-sig")
        self.query = {
            "content": self.source,
            "instance_id": INSTANCE,
            "instance_arn": INSTANCE_ARN,
            "region": "us-east-1",
            "name_overrides": "{}",
        }
        self.inventory = {
            "list-prompts": [{
                "Name": "CustomerQueueMOH", "Id": "dev-prompt",
                "Arn": INSTANCE_ARN + "/prompt/dev-prompt",
            }],
            "list-data-tables": [{
                "Name": "BTSGSD-V2V-US-PROMPT-DATATABLE", "Id": "dev-table",
                "Arn": INSTANCE_ARN + "/data-table/dev-table",
            }],
            "list-contact-flow-modules": [{
                "Name": MODULE_NAME, "Id": "dev-module", "State": "ACTIVE",
                "Arn": INSTANCE_ARN + "/contact-flow-module/dev-module",
            }],
        }

    def load(self, operation, result_key, query):
        self.assertEqual(query["instance_id"], INSTANCE)
        return self.inventory[operation]

    def test_resolves_target_ids_preserves_graph_and_integrations(self):
        output = json.loads(resolver.resolve(self.query, self.load)["content"])
        original = json.loads(self.source)
        self.assertEqual(len(output["Actions"]), len(original["Actions"]))
        self.assertEqual(output["StartAction"], original["StartAction"])
        for before, after in zip(original["Actions"], output["Actions"]):
            self.assertEqual(before["Identifier"], after["Identifier"])
            self.assertEqual(before["Type"], after["Type"])
            self.assertEqual(before["Transitions"], after["Transitions"])
            if before["Type"] in ("ConnectParticipantWithLexBot", "InvokeLambdaFunction"):
                self.assertEqual(before, after)
        params = [action["Parameters"] for action in output["Actions"]]
        self.assertEqual(next(p["PromptId"] for p in params if "PromptId" in p),
                         INSTANCE_ARN + "/prompt/dev-prompt")
        self.assertEqual(next(p["DataTableId"] for p in params if "DataTableId" in p),
                         "dev-table")
        self.assertEqual(next(p["FlowModuleId"] for p in params if "FlowModuleId" in p),
                         "dev-module:$LATEST")
        self.assertEqual(self.query["content"], self.source)

    def test_missing_dependencies_are_reported_together(self):
        self.inventory = {key: [] for key in self.inventory}
        with self.assertRaises(ValueError) as caught:
            resolver.resolve(self.query, self.load)
        for name in ("CustomerQueueMOH", "BTSGSD-V2V-US-PROMPT-DATATABLE", MODULE_NAME):
            self.assertIn(name, str(caught.exception))

    def test_survey_resolves_module_and_table_preserves_flow_graph(self):
        source = (
            REPO_DIR / "v2v_modules/aiagent_survey_flow/assets"
            / "BTSGSD-AIAgent-SurveyFlow.json"
        ).read_text(encoding="utf-8-sig")
        original = json.loads(source)
        identifiers = {action["Identifier"] for action in original["Actions"]}
        self.assertEqual(len(identifiers), len(original["Actions"]))
        self.assertEqual(len(identifiers), 20)
        self.assertIn(original["StartAction"], identifiers)
        self.assertEqual(set(original["Metadata"]["ActionMetadata"]), identifiers)
        for action in original["Actions"]:
            transitions = action["Transitions"]
            targets = [transitions.get("NextAction")]
            targets += [t["NextAction"] for t in transitions.get("Errors", [])]
            targets += [t["NextAction"] for t in transitions.get("Conditions", [])]
            for target in filter(None, targets):
                self.assertIn(target, identifiers)

        self.query["content"] = source
        self.query["name_overrides"] = json.dumps({
            MODULE_NAME: "VMX3_Main_VM_Module_btsgsd-dev-v2v-poc-us-east-1"
        })
        self.inventory["list-contact-flow-modules"][0]["Name"] = (
            "VMX3_Main_VM_Module_btsgsd-dev-v2v-poc-us-east-1"
        )
        output = json.loads(resolver.resolve(self.query, self.load)["content"])
        self.assertEqual(output["StartAction"], original["StartAction"])
        for before, after in zip(original["Actions"], output["Actions"]):
            self.assertEqual(before["Identifier"], after["Identifier"])
            self.assertEqual(before["Transitions"], after["Transitions"])
            if before["Type"] == "InvokeFlowModule":
                self.assertEqual(after["Parameters"]["FlowModuleId"], "dev-module:$LATEST")
            elif before["Type"] == "EvaluateDataTableValues":
                self.assertEqual(after["Parameters"]["DataTableId"], "dev-table")
                self.assertEqual(before["Parameters"]["Queries"], after["Parameters"]["Queries"])
            else:
                self.assertEqual(before, after)
        self.assertEqual(self.query["content"], source)

    def test_duplicate_names_do_not_choose_arbitrary_resource(self):
        self.inventory["list-prompts"].append(
            copy.deepcopy(self.inventory["list-prompts"][0])
        )
        with self.assertRaisesRegex(ValueError, "found 2"):
            resolver.resolve(self.query, self.load)

    def test_source_instance_arn_cannot_be_used_as_target(self):
        self.inventory["list-prompts"][0]["Arn"] = (
            "arn:aws:connect:us-east-1:518902362956:instance/old/prompt/old"
        )
        with self.assertRaisesRegex(ValueError, "outside the target instance"):
            resolver.resolve(self.query, self.load)

    def test_explicit_dev_name_override(self):
        self.query["name_overrides"] = json.dumps({"CustomerQueueMOH": "DevMOH"})
        self.inventory["list-prompts"][0]["Name"] = "DevMOH"
        output = json.loads(resolver.resolve(self.query, self.load)["content"])
        metadata = output["Metadata"]["ActionMetadata"]
        prompt_action = next(a for a in output["Actions"] if "PromptId" in a["Parameters"])
        self.assertEqual(metadata[prompt_action["Identifier"]]["promptName"], "DevMOH")

    def test_archived_module_is_not_usable(self):
        self.inventory["list-contact-flow-modules"][0]["State"] = "ARCHIVED"
        with self.assertRaisesRegex(ValueError, "FlowModuleId"):
            resolver.resolve(self.query, self.load)

    def test_incomplete_export_fails_before_aws_lookup(self):
        self.query["content"] = json.dumps({"StartAction": "missing"})
        with patch.object(resolver, "list_resources") as lookup:
            with self.assertRaisesRegex(ValueError, "missing Actions"):
                resolver.resolve(self.query, lookup)
            lookup.assert_not_called()

    def test_cli_failure_is_reported_as_access_failure(self):
        with patch.object(resolver.subprocess, "run") as run:
            run.return_value.returncode = 1
            run.return_value.stderr = "AccessDeniedException: connect:ListPrompts"
            with self.assertRaisesRegex(RuntimeError, "AccessDeniedException"):
                resolver.list_resources("list-prompts", "PromptSummaryList", self.query)
            command = run.call_args.args[0]
            self.assertEqual(command[:3], ["aws", "connect", "list-prompts"])
            self.assertIn(INSTANCE, command)

    def test_old_cli_has_actionable_upgrade_error(self):
        with patch.object(resolver.subprocess, "run") as run:
            run.return_value.returncode = 2
            run.return_value.stderr = "Invalid choice: 'list-data-tables'"
            with self.assertRaisesRegex(RuntimeError, "Upgrade AWS CLI v2"):
                resolver.list_resources("list-data-tables", "DataTableSummaryList", self.query)

    def test_missing_cli_has_actionable_install_error(self):
        with patch.object(resolver.subprocess, "run", side_effect=FileNotFoundError):
            with self.assertRaisesRegex(RuntimeError, "AWS CLI is not installed"):
                resolver.list_resources("list-prompts", "PromptSummaryList", self.query)


if __name__ == "__main__":
    unittest.main()
