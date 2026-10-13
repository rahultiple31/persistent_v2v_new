import copy
import importlib.util
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "admin_profiles", Path(__file__).resolve().parents[1] / "assign_admin_security_profile.py"
)
profiles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profiles)

ACCOUNT = "518902362956"
INSTANCE = "c227a737-3e4f-4c64-8397-2d37e318801d"
ASSISTANT = "bc274e3f-380d-45e7-968f-2d19f92acd74"
ADMIN = "00000000-0000-0000-0000-000000000001"
AGENTS = ["504e3842-050d-4866-a253-9a38e766cc3f", "4c72ff92-b382-488e-8edd-21a6648f5916"]
OLD_PROFILES = ["79c5410f-bd4a-4c9d-9523-6abd298b2a50", "3f4ec880-e8b9-4b1d-93f2-beb1f1d4c075"]


def arn(agent):
    return f"arn:aws:wisdom:us-east-1:{ACCOUNT}:ai-agent/{ASSISTANT}/{agent}"


class FakeAws:
    def __init__(self):
        self.calls = []
        self.account = ACCOUNT
        self.profile_name = "Admin"
        self.integrations = [{"IntegrationArn": f"arn:aws:wisdom:us-east-1:{ACCOUNT}:assistant/{ASSISTANT}"}]
        self.agents = [{"aiAgentId": item, "aiAgentArn": arn(item), "name": f"custom-{index}", "origin": "CUSTOMER"} for index, item in enumerate(AGENTS)]
        self.versions = {AGENTS[0]: [1], AGENTS[1]: []}
        self.attached = {
            arn(AGENTS[0]) + ":$LATEST": {OLD_PROFILES[0]},
            arn(AGENTS[0]) + ":1": {OLD_PROFILES[0]},
            arn(AGENTS[1]) + ":$LATEST": {OLD_PROFILES[1]},
        }
        self.fail_on = None
        self.ignore_associate = False
        self.ignore_disassociate = False

    def writes(self, operation=None):
        return [call for call in self.calls if call[1] in {"associate-security-profiles", "disassociate-security-profiles"} and (operation is None or call[1] == operation)]

    def __call__(self, service, operation, *arguments):
        self.calls.append((service, operation, arguments))
        if operation == self.fail_on:
            raise RuntimeError("AccessDeniedException")
        def value(flag):
            return arguments[arguments.index(flag) + 1]
        if operation == "get-caller-identity":
            return {"Account": self.account}
        if operation == "describe-security-profile":
            return {"SecurityProfile": {"SecurityProfileName": self.profile_name}}
        if operation == "get-assistant":
            return {"assistant": {"assistantArn": f"arn:aws:wisdom:us-east-1:{ACCOUNT}:assistant/{ASSISTANT}"}}
        if operation == "list-integration-associations":
            return {"IntegrationAssociationSummaryList": self.integrations}
        if operation == "list-ai-agents":
            assert value("--origin") == "CUSTOMER"
            return {"aiAgentSummaries": copy.deepcopy(self.agents)}
        if operation == "list-ai-agent-versions":
            return {"aiAgentVersionSummaries": [{"versionNumber": number} for number in self.versions[value("--ai-agent-id")]]}
        if operation == "list-entity-security-profiles":
            return {"SecurityProfiles": [{"Id": item} for item in self.attached[value("--entity-arn")]]}
        if operation == "associate-security-profiles":
            if not self.ignore_associate:
                self.attached[value("--entity-arn")].update(item["Id"] for item in json.loads(value("--security-profiles")))
            return {}
        if operation == "disassociate-security-profiles":
            if not self.ignore_disassociate:
                self.attached[value("--entity-arn")].difference_update(item["Id"] for item in json.loads(value("--security-profiles")))
            return {}
        raise AssertionError(f"Unexpected operation {service} {operation}")


class AdminProfileTest(unittest.TestCase):
    def setUp(self):
        self.config = {
            "connect_instance_arn": f"arn:aws:connect:us-east-1:{ACCOUNT}:instance/{INSTANCE}",
            "assistant_id": ASSISTANT, "admin_profile_id": ADMIN, "region": "us-east-1",
        }
        self.aws = FakeAws()
        self.messages = []

    def migrate(self):
        return profiles.migrate(self.config, self.aws, self.messages.append, sleep=lambda seconds: None)

    def test_migrates_reported_agents_and_published_version_to_admin(self):
        self.assertEqual(self.migrate(), 3)
        self.assertTrue(all(ids == {ADMIN} for ids in self.aws.attached.values()))
        self.assertEqual(len(self.aws.writes("associate-security-profiles")), 3)
        operations = [operation for _, operation, _ in self.aws.calls]
        last_association = max(index for index, operation in enumerate(operations) if operation == "associate-security-profiles")
        self.assertGreater(operations.index("disassociate-security-profiles"), last_association)

    def test_already_admin_only_is_idempotent(self):
        self.migrate()
        self.aws.calls.clear()
        self.assertEqual(self.migrate(), 3)
        self.assertEqual(self.aws.writes(), [])

    def test_admin_with_old_profiles_only_detaches_old_profiles(self):
        for ids in self.aws.attached.values():
            ids.add(ADMIN)
        self.migrate()
        self.assertEqual(self.aws.writes("associate-security-profiles"), [])
        for _, _, arguments in self.aws.writes("disassociate-security-profiles"):
            ids = json.loads(arguments[arguments.index("--security-profiles") + 1])
            self.assertNotIn(ADMIN, [item["Id"] for item in ids])

    def test_no_profiles_attached_gets_admin(self):
        self.aws.attached = {key: set() for key in self.aws.attached}
        self.migrate()
        self.assertTrue(all(ids == {ADMIN} for ids in self.aws.attached.values()))
        self.assertEqual(self.aws.writes("disassociate-security-profiles"), [])

    def test_system_agents_are_not_modified(self):
        self.aws.agents.append({"origin": "SYSTEM", "name": "SelfServiceOrchestratorVoice"})
        self.assertEqual(self.migrate(), 3)

    def test_agents_for_other_instances_are_not_modified(self):
        self.aws.agents[1]["configuration"] = {"orchestrationAIAgentConfiguration": {"connectInstanceArn": "arn:other-instance"}}
        self.assertEqual(self.migrate(), 2)
        self.assertEqual(self.aws.attached[arn(AGENTS[1]) + ":$LATEST"], {OLD_PROFILES[1]})

    def test_wrong_account_or_region_blocks_writes(self):
        self.aws.account = "000000000000"
        with self.assertRaisesRegex(ValueError, "account"):
            self.migrate()
        self.config["region"] = "us-west-2"
        with self.assertRaisesRegex(ValueError, "region"):
            self.migrate()
        self.assertEqual(self.aws.writes(), [])

    def test_wrong_profile_name_blocks_writes(self):
        self.aws.profile_name = "Agent"
        with self.assertRaisesRegex(ValueError, "existing Admin"):
            self.migrate()
        self.assertEqual(self.aws.writes(), [])

    def test_wrong_assistant_integration_blocks_writes(self):
        self.aws.integrations = []
        with self.assertRaisesRegex(ValueError, "not associated"):
            self.migrate()
        self.assertEqual(self.aws.writes(), [])

    def test_agent_arn_from_other_assistant_blocks_writes(self):
        self.aws.agents[1]["aiAgentArn"] = "arn:aws:wisdom:us-east-1:518902362956:ai-agent/other/agent"
        with self.assertRaisesRegex(ValueError, "ARN does not match"):
            self.migrate()
        self.assertEqual(self.aws.writes(), [])

    def test_discovery_permission_failure_blocks_all_writes(self):
        self.aws.fail_on = "list-entity-security-profiles"
        with self.assertRaisesRegex(RuntimeError, "AccessDenied"):
            self.migrate()
        self.assertEqual(self.aws.writes(), [])

    def test_failed_admin_assignment_keeps_old_profiles(self):
        self.aws.fail_on = "associate-security-profiles"
        with self.assertRaises(RuntimeError):
            self.migrate()
        self.assertEqual(self.aws.writes("disassociate-security-profiles"), [])
        self.assertEqual(self.aws.attached[arn(AGENTS[0]) + ":$LATEST"], {OLD_PROFILES[0]})

    def test_unverified_admin_assignment_keeps_old_profiles(self):
        self.aws.ignore_associate = True
        with self.assertRaisesRegex(RuntimeError, "previous profiles were retained"):
            self.migrate()
        self.assertEqual(self.aws.writes("disassociate-security-profiles"), [])

    def test_disassociation_failure_stops_with_admin_retained(self):
        self.aws.fail_on = "disassociate-security-profiles"
        with self.assertRaises(RuntimeError):
            self.migrate()
        self.assertTrue(all(ADMIN in ids for ids in self.aws.attached.values()))

    def test_unverified_detachment_fails(self):
        self.aws.ignore_disassociate = True
        with self.assertRaisesRegex(RuntimeError, "Admin-only"):
            self.migrate()

    def test_no_custom_agents_is_a_noop(self):
        self.aws.agents = []
        self.assertEqual(self.migrate(), 0)
        self.assertEqual(self.aws.writes(), [])

    def test_cli_preserves_latest_and_inherits_oidc_credentials(self):
        response = type("Response", (), {"returncode": 0, "stdout": "{}", "stderr": ""})()
        def fake_migrate(config, aws):
            aws("connect", "associate-security-profiles", "--entity-arn", arn(AGENTS[0]) + ":$LATEST")
        with patch.dict(os.environ, {"AI_AGENT_ADMIN_PROFILE_CONFIG": json.dumps(self.config), "AWS_ROLE_ARN": "role", "AWS_WEB_IDENTITY_TOKEN_FILE": "token-path"}):
            with patch.object(profiles, "migrate", side_effect=fake_migrate):
                with patch.object(profiles.subprocess, "run", return_value=response) as run:
                    profiles.main()
        args = run.call_args.args[0]
        self.assertEqual(args[args.index("--entity-arn") + 1], arn(AGENTS[0]) + ":$LATEST")
        self.assertNotIn("--no-paginate", args)
        self.assertNotIn("shell", run.call_args.kwargs)
        self.assertEqual(run.call_args.kwargs["env"]["AWS_WEB_IDENTITY_TOKEN_FILE"], "token-path")


if __name__ == "__main__":
    unittest.main()
