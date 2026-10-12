import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "manage_security_profiles",
    Path(__file__).resolve().parents[1] / "manage_security_profiles.py",
)
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)


class SecurityProfileAssociationTest(unittest.TestCase):
    def setUp(self):
        self.agent = "arn:aws:wisdom:us-east-1:123456789012:ai-agent/assistant/agent"
        self.query = {
            "instance_id": "instance-id",
            "security_profile_id": "retrieval-profile",
            "agent_arns": [self.agent, self.agent + ":1"],
            "account_id": "123456789012",
            "region": "us-east-1",
            "aws_profile": "",
        }
        self.attached = {
            self.agent: {"existing-profile"},
            self.agent + ":1": {"existing-profile"},
        }
        self.mutations = []

    def aws(self, service, operation, *arguments):
        if service == "sts":
            return {"Account": "123456789012"}
        arn = arguments[arguments.index("--entity-arn") + 1]
        self.assertEqual(arguments[arguments.index("--entity-type") + 1], "AI_AGENT")
        self.assertEqual(arguments[arguments.index("--instance-id") + 1], "instance-id")
        if operation == "list-entity-security-profiles":
            return {"SecurityProfiles": [{"Id": value} for value in self.attached[arn]]}
        profiles = json.loads(arguments[arguments.index("--security-profiles") + 1])
        self.assertEqual(profiles, [{"Id": "retrieval-profile"}])
        self.mutations.append((operation, arn))
        if operation == "associate-security-profiles":
            self.attached[arn].add("retrieval-profile")
        else:
            self.assertEqual(operation, "disassociate-security-profiles")
            self.attached[arn].remove("retrieval-profile")
        return {}

    def test_associates_draft_and_version_without_removing_other_profiles(self):
        manager.reconcile(self.query, "associate", self.aws)
        self.assertEqual(len(self.mutations), 2)
        for profiles in self.attached.values():
            self.assertEqual(profiles, {"existing-profile", "retrieval-profile"})

    def test_repeated_association_is_idempotent(self):
        manager.reconcile(self.query, "associate", self.aws)
        self.mutations.clear()
        manager.reconcile(self.query, "associate", self.aws)
        self.assertEqual(self.mutations, [])

    def test_only_associates_missing_version(self):
        self.attached[self.agent].add("retrieval-profile")
        manager.reconcile(self.query, "associate", self.aws)
        self.assertEqual(self.mutations, [("associate-security-profiles", self.agent + ":1")])

    def test_destroy_removes_only_the_managed_profile(self):
        manager.reconcile(self.query, "associate", self.aws)
        self.mutations.clear()
        manager.reconcile(self.query, "disassociate", self.aws)
        self.assertEqual(len(self.mutations), 2)
        for profiles in self.attached.values():
            self.assertEqual(profiles, {"existing-profile"})

    def test_destroy_is_idempotent_when_profile_not_attached(self):
        manager.reconcile(self.query, "disassociate", self.aws)
        self.assertEqual(self.mutations, [])

    def test_rejects_wrong_aws_account_before_mutation(self):
        self.query["account_id"] = "999999999999"
        with self.assertRaisesRegex(ValueError, "same AWS account"):
            manager.reconcile(self.query, "associate", self.aws)
        self.assertEqual(self.mutations, [])

    def test_validates_all_arns_before_any_mutation(self):
        self.query["agent_arns"][1] = self.agent.replace("us-east-1", "us-west-2")
        with self.assertRaisesRegex(ValueError, "provider account and region"):
            manager.reconcile(self.query, "associate", self.aws)
        self.assertEqual(self.mutations, [])

    def test_destroy_tolerates_deleted_agents(self):
        def deleted(service, operation, *arguments):
            if service == "sts":
                return {"Account": "123456789012"}
            raise manager.AwsCliError("ResourceNotFoundException")

        manager.reconcile(self.query, "disassociate", deleted)

    def test_association_does_not_ignore_missing_agent(self):
        def deleted(service, operation, *arguments):
            if service == "sts":
                return {"Account": "123456789012"}
            raise manager.AwsCliError("ResourceNotFoundException")

        with self.assertRaises(manager.AwsCliError):
            manager.reconcile(self.query, "associate", deleted)

    def test_does_not_ignore_access_denied(self):
        def denied(service, operation, *arguments):
            if service == "sts":
                return {"Account": "123456789012"}
            raise manager.AwsCliError("AccessDeniedException")

        for action in ("associate", "disassociate"):
            with self.assertRaises(manager.AwsCliError):
                manager.reconcile(self.query, action, denied)

    def test_cli_handles_empty_success_response_and_passes_profile(self):
        self.query["aws_profile"] = "pipeline-profile"
        outputs = [
            '{"Account": "123456789012"}',
            '{"SecurityProfiles": []}', "",
            '{"SecurityProfiles": []}', "",
        ]
        with patch.dict(manager.os.environ, {
            "AI_SECURITY_QUERY": json.dumps(self.query),
            "AI_SECURITY_ACTION": "associate",
        }), patch.object(manager.subprocess, "run") as run, patch("builtins.print"):
            run.side_effect = [
                manager.subprocess.CompletedProcess([], 0, stdout, "") for stdout in outputs
            ]
            manager.main()
        self.assertEqual(run.call_count, 5)
        for call in run.call_args_list:
            command = call.args[0]
            self.assertEqual(command[-2:], ["--profile", "pipeline-profile"])

    def test_cli_retries_missing_agent_then_succeeds(self):
        with patch.dict(manager.os.environ, {
            "AI_SECURITY_QUERY": json.dumps(self.query),
            "AI_SECURITY_ACTION": "associate",
        }), patch.object(manager.subprocess, "run") as run, patch.object(
            manager.time, "sleep"
        ) as sleep, patch("builtins.print"):
            run.side_effect = [
                manager.subprocess.CompletedProcess([], 0, '{"Account": "123456789012"}', ""),
                manager.subprocess.CompletedProcess([], 1, "", "ResourceNotFoundException"),
                manager.subprocess.CompletedProcess([], 0, '{"SecurityProfiles": []}', ""),
                manager.subprocess.CompletedProcess([], 0, "", ""),
                manager.subprocess.CompletedProcess([], 0, '{"SecurityProfiles": []}', ""),
                manager.subprocess.CompletedProcess([], 0, "", ""),
            ]
            manager.main()
        sleep.assert_called_once_with(1)

    def test_cli_missing_agent_retry_budget_is_bounded(self):
        with patch.dict(manager.os.environ, {
            "AI_SECURITY_QUERY": json.dumps(self.query),
            "AI_SECURITY_ACTION": "associate",
        }), patch.object(manager.subprocess, "run") as run, patch.object(
            manager.time, "sleep"
        ) as sleep:
            run.side_effect = [
                manager.subprocess.CompletedProcess([], 0, '{"Account": "123456789012"}', ""),
                *[manager.subprocess.CompletedProcess([], 1, "", "ResourceNotFoundException") for _ in range(5)],
            ]
            with self.assertRaises(manager.AwsCliError):
                manager.main()
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [1, 2, 4, 8])
        self.assertEqual(run.call_count, 6)


if __name__ == "__main__":
    unittest.main()
