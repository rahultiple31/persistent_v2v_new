import copy
import importlib.util
import json
from pathlib import Path
import re
import unittest
from unittest.mock import patch


MODULE_DIR = Path(__file__).resolve().parents[1]
REPO_DIR = MODULE_DIR.parents[1]
SPEC = importlib.util.spec_from_file_location(
    "resolver", REPO_DIR / "v2v_modules/connect_flow_resource/scripts/resolve_customer_queue_dependencies.py"
)
resolver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(resolver)

INSTANCE = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
INSTANCE_ARN = f"arn:aws:connect:us-east-1:518902362956:instance/{INSTANCE}"
MODULE_NAME = "BTSGSD-V2V-US-VMX3_Main_VM_Module"
QUEUE_BOT = ("BTSGSD-V2V-US-customerQueueFlowBot", "CQBOT00001", "CQALIAS001")
YESNO_BOT = ("BTSGSD-V2V-US-yesNo", "YNBOT00001", "YNALIAS001")
def alias_arn(bot):
    return f"arn:aws:lex:us-east-1:518902362956:bot-alias/{bot[1]}/{bot[2]}"


class DependencyResolutionTests(unittest.TestCase):
    def setUp(self):
        self.source = (
            REPO_DIR / "v2v_modules/customer_queue_flow/assets"
            / "BTSGSD_Abbvie_CustomerQueueFlow.json"
        ).read_text(encoding="utf-8-sig")
        configuration = (REPO_DIR / "environments/v2v-dev/terraform.tfvars").read_text(encoding="utf-8-sig")
        override_block = re.search(
            r"connect_customer_queue_dependency_names\s*=\s*\{(.*?)\n\}",
            configuration, re.DOTALL,
        ).group(1)
        self.overrides = dict(re.findall(r'"([^"\n]+)"\s*=\s*"([^"\n]+)"', override_block))
        self.query = {
            "content": self.source,
            "instance_id": INSTANCE,
            "instance_arn": INSTANCE_ARN,
            "region": "us-east-1",
            "name_overrides": json.dumps(self.overrides),
        }
        self.inventory = {
            "list-prompts": [{
                "Name": "MOH_30SEC", "Id": "dev-prompt",
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
            "list-queues": [
                {"Name": "BTSGSD-V2V-LATAM-OUT-QUEUE", "Id": "latam-out",
                 "Arn": INSTANCE_ARN + "/queue/latam-out"},
                {"Name": "BTSGSD-V2V-US-OUT-QUEUE", "Id": "us-out",
                 "Arn": INSTANCE_ARN + "/queue/us-out"},
            ],
            # Same names in the source account must not be picked up.
            "lexv2-models list-bots": [
                {"botName": QUEUE_BOT[0], "botId": QUEUE_BOT[1]},
                {"botName": YESNO_BOT[0], "botId": YESNO_BOT[1]},
                {"botName": "BTSGSD-SSO-US-yesNo", "botId": "QT2GQYM5TT"},
            ],
            f"lexv2-models list-bot-aliases:{QUEUE_BOT[1]}": [
                {"botAliasName": "TestBotAlias", "botAliasId": "TSTALIASID"},
                {"botAliasName": "BTSGSD-V2V-US-DEV", "botAliasId": QUEUE_BOT[2]},
            ],
            f"lexv2-models list-bot-aliases:{YESNO_BOT[1]}": [
                {"botAliasName": "BTSGSD-V2V-US-DEV", "botAliasId": YESNO_BOT[2]},
            ],
            "list-bots": [
                {"LexV2Bot": {"AliasArn": alias_arn(QUEUE_BOT)}},
                {"LexV2Bot": {"AliasArn": alias_arn(YESNO_BOT)}},
            ],
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
            if before["Type"] == "InvokeLambdaFunction":
                self.assertEqual(before, after)
            if before["Type"] == "ConnectParticipantWithLexBot":
                self.assertEqual(
                    {k: v for k, v in before["Parameters"].items() if k != "LexV2Bot"},
                    {k: v for k, v in after["Parameters"].items() if k != "LexV2Bot"},
                )
        params = [action["Parameters"] for action in output["Actions"]]
        self.assertEqual(next(p["PromptId"] for p in params if "PromptId" in p),
                         INSTANCE_ARN + "/prompt/dev-prompt")
        self.assertEqual(next(p["DataTableId"] for p in params if "DataTableId" in p),
                         "dev-table")
        self.assertEqual(next(p["FlowModuleId"] for p in params if "FlowModuleId" in p),
                         "dev-module:$LATEST")
        self.assertEqual(self.query["content"], self.source)

    def test_lex_blocks_use_the_target_bots_and_labels(self):
        output = json.loads(resolver.resolve(self.query, self.load)["content"])
        actions = {action["Identifier"]: action for action in output["Actions"]}
        metadata = output["Metadata"]["ActionMetadata"]
        for identifier, bot in (
            ("Virtual  Queue or  Voicemail", QUEUE_BOT),
            ("54b3000f-eba8-43ea-a040-c815c87a877d", YESNO_BOT),
            ("e853af02-ee8d-40e8-8855-9d5f7b5b4909", YESNO_BOT),
        ):
            with self.subTest(block=identifier):
                self.assertEqual(actions[identifier]["Parameters"]["LexV2Bot"]["AliasArn"], alias_arn(bot))
                shown = metadata[identifier]["parameters"]["LexV2Bot"]["AliasArn"]
                self.assertEqual((shown["lexV2BotName"], shown["displayName"]), (bot[0], "BTSGSD-V2V-US-DEV"))
                self.assertEqual(metadata[identifier]["lexV2BotName"], bot[0])
                self.assertEqual(metadata[identifier]["lexV2BotAliasName"], "BTSGSD-V2V-US-DEV")
        text = json.dumps(output)
        for source in ("RD35A35EAU", "QT2GQYM5TT", "BTSGSD-SSO-US-", "c227a737-3e4f-4c64-8397-2d37e318801d"):
            self.assertNotIn(source, text)

    def test_lambda_label_names_the_invoked_function(self):
        target = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-conversionOfQueueMetrics"
        self.query["content"] = self.source.replace(
            "arn:aws:lambda:us-east-1:518902362956:function:conversionOfQueueMetrics-dev", target
        )
        output = json.loads(resolver.resolve(self.query, self.load)["content"])
        action = next(a for a in output["Actions"] if a["Type"] == "InvokeLambdaFunction")
        shown = output["Metadata"]["ActionMetadata"][action["Identifier"]]["parameters"]["LambdaFunctionARN"]
        self.assertEqual(shown["displayName"], "BTSGSD-V2V-US-conversionOfQueueMetrics")

    def test_lex_alias_must_be_associated_with_the_target_instance(self):
        self.inventory["list-bots"] = [{"LexV2Bot": {"AliasArn": alias_arn(QUEUE_BOT)}}]
        with self.assertRaisesRegex(ValueError, "'BTSGSD-V2V-US-yesNo' alias 'BTSGSD-V2V-US-DEV' is not associated"):
            resolver.resolve(self.query, self.load)

    def test_missing_or_duplicate_lex_bots_and_aliases_are_rejected(self):
        for problem in ("no-bot", "two-bots", "no-alias"):
            with self.subTest(problem=problem):
                self.setUp()
                if problem == "no-bot":
                    self.inventory["lexv2-models list-bots"].pop(0)
                    expected = "one Lex bot named 'BTSGSD-V2V-US-customerQueueFlowBot', found 0"
                elif problem == "two-bots":
                    self.inventory["lexv2-models list-bots"].append({"botName": YESNO_BOT[0], "botId": "OTHER00001"})
                    expected = "one Lex bot named 'BTSGSD-V2V-US-yesNo', found 2"
                else:
                    self.inventory[f"lexv2-models list-bot-aliases:{YESNO_BOT[1]}"] = []
                    expected = "one alias named 'BTSGSD-V2V-US-DEV' on 'BTSGSD-V2V-US-yesNo', found 0"
                with self.assertRaisesRegex(ValueError, expected):
                    resolver.resolve(self.query, self.load)

    def test_lex_lookups_are_made_once(self):
        with patch.object(self, "load", wraps=self.load) as loader:
            resolver.resolve(self.query, loader)
        operations = [call.args[0] for call in loader.call_args_list]
        for operation in ("lexv2-models list-bots", "list-bots", f"lexv2-models list-bot-aliases:{YESNO_BOT[1]}"):
            self.assertEqual(operations.count(operation), 1, operation)

    def test_dynamic_lex_alias_is_left_unchanged(self):
        flow = json.loads(self.source)
        for action in flow["Actions"]:
            if "LexV2Bot" in action.get("Parameters", {}):
                action["Parameters"]["LexV2Bot"]["AliasArn"] = "$.Attributes.botAlias"
        self.query["content"] = json.dumps(flow)
        self.inventory["list-bots"] = []
        output = json.loads(resolver.resolve(self.query, self.load)["content"])
        for action in output["Actions"]:
            if "LexV2Bot" in action.get("Parameters", {}):
                self.assertEqual(action["Parameters"]["LexV2Bot"]["AliasArn"], "$.Attributes.botAlias")

    def test_lex_cli_commands(self):
        with patch.object(resolver.subprocess, "run") as run:
            run.return_value.returncode = 0
            run.return_value.stdout = json.dumps({"botAliasSummaries": [], "LexBots": []})
            resolver.list_resources(f"lexv2-models list-bot-aliases:{YESNO_BOT[1]}", "botAliasSummaries", self.query)
            self.assertEqual(run.call_args.args[0][:5], ["aws", "lexv2-models", "list-bot-aliases", "--bot-id", YESNO_BOT[1]])
            resolver.list_resources("list-bots", "LexBots", self.query)
            command = run.call_args.args[0]
            self.assertEqual(command[:5], ["aws", "connect", "list-bots", "--instance-id", INSTANCE])
            self.assertEqual(command[5:7], ["--lex-version", "V2"])

    def test_missing_dependencies_are_reported_together(self):
        self.inventory = {key: [] for key in self.inventory}
        with self.assertRaises(ValueError) as caught:
            resolver.resolve(self.query, self.load)
        for name in ("MOH_30SEC", "BTSGSD-V2V-US-PROMPT-DATATABLE", MODULE_NAME):
            self.assertIn(name, str(caught.exception))

    def test_survey_resolves_module_and_table_preserves_flow_graph(self):
        source = (
            REPO_DIR / "v2v_modules/aiagent_survey_flow/assets"
            / "BTSGSD-AIAgent-SurveyFlow.json"
        ).read_text(encoding="utf-8-sig")
        original = json.loads(source)
        identifiers = {action["Identifier"] for action in original["Actions"]}
        self.assertEqual(len(identifiers), len(original["Actions"]))
        self.assertEqual(len(identifiers), 43)
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
        self.query["name_overrides"] = json.dumps(dict(self.overrides, MOH_30SEC="DevMOH"))
        self.inventory["list-prompts"][0]["Name"] = "DevMOH"
        output = json.loads(resolver.resolve(self.query, self.load)["content"])
        metadata = output["Metadata"]["ActionMetadata"]
        prompt_action = next(a for a in output["Actions"] if "PromptId" in a["Parameters"])
        self.assertEqual(metadata[prompt_action["Identifier"]]["promptName"], "DevMOH")

    def test_archived_module_is_not_usable(self):
        self.inventory["list-contact-flow-modules"][0]["State"] = "ARCHIVED"
        with self.assertRaisesRegex(ValueError, "FlowModuleId"):
            resolver.resolve(self.query, self.load)

    def test_complete_attachment_has_valid_graph_and_target_flow_name(self):
        flow = json.loads(self.source)
        identifiers = [action["Identifier"] for action in flow["Actions"]]
        self.assertEqual(len(identifiers), 44)
        self.assertEqual(len(identifiers), len(set(identifiers)))
        self.assertIn(flow["StartAction"], identifiers)
        self.assertEqual(flow["Metadata"]["name"], "BTSGSD-V2V-US-CustomerQueueFlow")
        for action in flow["Actions"]:
            transitions = action.get("Transitions", {})
            destinations = [transitions["NextAction"]] if transitions.get("NextAction") else []
            for section in ("Conditions", "Errors"):
                destinations.extend(item["NextAction"] for item in transitions.get(section, []))
            for destination in destinations:
                self.assertIn(destination, identifiers)

    def test_callback_branches_use_target_queues_and_one_inventory_lookup(self):
        with patch.object(self, "load", wraps=self.load) as loader:
            output = json.loads(resolver.resolve(self.query, loader)["content"])
        actions = {action["Identifier"]: action for action in output["Actions"]}
        for identifier, queue in (
            ("3f058ced-c01e-461c-b15e-e808ace284f3", "latam-out"),
            ("f642c8e3-c3c1-43ee-9874-55a535c73d36", "us-out"),
        ):
            self.assertEqual(actions[identifier]["Parameters"]["Attributes"]["callbackOutboundQueue"],
                             INSTANCE_ARN + "/queue/" + queue)
        queue_calls = [call for call in loader.call_args_list if call.args[0] == "list-queues"]
        self.assertEqual(len(queue_calls), 1)
        self.assertEqual(queue_calls[0].args[1], "QueueSummaryList")
        self.assertNotIn("instance/c227a737-3e4f-4c64-8397-2d37e318801d/", json.dumps(output["Actions"]))

    def test_source_callback_queues_require_explicit_target_mapping(self):
        self.query["name_overrides"] = json.dumps({
            key: value for key, value in self.overrides.items() if not key.startswith("arn:")
        })
        with self.assertRaisesRegex(ValueError, "requires a target queue-name mapping"):
            resolver.resolve(self.query, self.load)

    def test_duplicate_missing_or_other_instance_callback_queues_are_rejected(self):
        original = copy.deepcopy(self.inventory["list-queues"])
        for problem in ("duplicate", "missing", "other-instance", "no-arn"):
            with self.subTest(problem=problem):
                queues = copy.deepcopy(original)
                if problem == "duplicate":
                    queues.append(copy.deepcopy(queues[0]))
                elif problem == "missing":
                    queues.pop(0)
                elif problem == "other-instance":
                    queues[0]["Arn"] = "arn:aws:connect:us-east-1:518902362956:instance/other/queue/wrong"
                else:
                    queues[0].pop("Arn")
                self.inventory["list-queues"] = queues
                with self.assertRaisesRegex(ValueError, "callbackOutboundQueue"):
                    resolver.resolve(self.query, self.load)

    def test_existing_target_callback_queue_is_preserved_without_lookup(self):
        flow = json.loads(self.source)
        for action in flow["Actions"]:
            attributes = action.get("Parameters", {}).get("Attributes", {})
            if "callbackOutboundQueue" in attributes:
                attributes["callbackOutboundQueue"] = INSTANCE_ARN + "/queue/already-target"
        self.query["content"] = json.dumps(flow)
        with patch.object(self, "load", wraps=self.load) as loader:
            output = json.loads(resolver.resolve(self.query, loader)["content"])
        self.assertFalse(any(call.args[0] == "list-queues" for call in loader.call_args_list))
        for action in output["Actions"]:
            attributes = action.get("Parameters", {}).get("Attributes", {})
            if "callbackOutboundQueue" in attributes:
                self.assertEqual(attributes["callbackOutboundQueue"], INSTANCE_ARN + "/queue/already-target")

    def test_module_replacements_match_the_new_attachment_without_lambda_suffix(self):
        module = (REPO_DIR / "v2v_modules/customer_queue_flow/main.tf").read_text()
        lambda_pattern = re.search(r'"([^"\n]+)"\s*,\s*var.settings.queue_metrics_lambda_arn', module).group(1)
        table_pattern = re.search(r'"([^"\n]+)"\s*,\s*var.settings.survey_data_table_id', module).group(1)
        target_lambda = "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-conversionOfQueueMetrics"
        rendered = json.loads(self.source.replace(lambda_pattern, target_lambda).replace(table_pattern, "dev-table"))
        for action in rendered["Actions"]:
            if action["Type"] == "InvokeLambdaFunction":
                self.assertEqual(action["Parameters"]["LambdaFunctionARN"], target_lambda)
            if action["Type"] == "EvaluateDataTableValues":
                self.assertEqual(action["Parameters"]["DataTableId"], "dev-table")

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
