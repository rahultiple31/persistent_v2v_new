import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "admin_mcp_tools", Path(__file__).resolve().parents[1] / "grant_admin_mcp_tools.py"
)
ACCESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ACCESS)

INSTANCE = "bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
AGENT = "arn:aws:wisdom:us-east-1:518902362956:ai-agent/assistant-id/support-agent-id"
TOOLS = [
    "BTSGSD-V2V-US-nexthink-handoff___handoff",
    "BTSGSD-V2V-US-snow-interaction___Interaction__Interaction",
    "BTSGSD-V2V-US-snow-userlookup___UserLookUp___UserLookUp",
]
CONFIG = {
    "connect_instance_arn": f"arn:aws:connect:us-east-1:518902362956:instance/{INSTANCE}",
    "namespace": "gateway-0123456789",
    "tool_names": TOOLS,
    "agent_arns": [AGENT, AGENT + ":2"],
    "aws_profile": "deployment-profile",
}


class FakeAws:
    def __init__(self):
        self.calls = []
        self.account = "518902362956"
        self.profiles = [{"Name": "Admin", "Id": "admin-id"}]
        self.applications = [
            {"Namespace": "other-app", "Type": "THIRD_PARTY_APPLICATION", "ApplicationPermissions": ["ACCESS"]},
            {"Namespace": CONFIG["namespace"], "Type": "MCP", "ApplicationPermissions": ["existing-tool"]},
        ]
        self.attached = {arn: {"existing-profile"} for arn in CONFIG["agent_arns"]}
        self.attached[AGENT.replace("support-agent-id", "other-agent-id") + ":1"] = {"other-profile"}
        self.fail_on = None
        self.ignore_update = False
        self.ignore_associate = False

    def __call__(self, region, service, operation, *, aws_profile="", **payload):
        self.calls.append((region, service, operation, aws_profile, copy.deepcopy(payload)))
        if operation == self.fail_on:
            raise RuntimeError("AccessDeniedException")
        if operation == "get-caller-identity":
            return {"Account": self.account}
        if operation == "list-security-profiles":
            return {"SecurityProfileSummaryList": copy.deepcopy(self.profiles)}
        if operation == "list-security-profile-applications":
            return {"Applications": copy.deepcopy(self.applications)}
        if operation == "update-security-profile":
            if not self.ignore_update:
                self.applications = copy.deepcopy(payload["Applications"])
            return {}
        if operation == "list-entity-security-profiles":
            return {"SecurityProfiles": [{"Id": item} for item in self.attached[payload["EntityArn"]]]}
        if operation == "associate-security-profiles":
            if not self.ignore_associate:
                self.attached[payload["EntityArn"]].update(item["Id"] for item in payload["SecurityProfiles"])
            return {}
        raise AssertionError(operation)

    def writes(self):
        return [call for call in self.calls if call[2] in ("update-security-profile", "associate-security-profiles")]


class AdminMcpAccessTests(unittest.TestCase):
    def setUp(self):
        self.config = copy.deepcopy(CONFIG)
        self.aws = FakeAws()

    def grant(self):
        return ACCESS.grant(self.config, self.aws, sleep=lambda seconds: None)

    def test_adds_three_tools_preserves_existing_access_and_scopes_agent_versions(self):
        before = copy.deepcopy(self.aws.attached)
        self.assertEqual(self.grant(), 2)
        self.assertEqual(self.aws.applications[0], {
            "Namespace": "other-app", "Type": "THIRD_PARTY_APPLICATION", "ApplicationPermissions": ["ACCESS"],
        })
        self.assertEqual(set(self.aws.applications[1]["ApplicationPermissions"]), set(TOOLS) | {"existing-tool"})
        updates = [call[4] for call in self.aws.writes() if call[2] == "update-security-profile"]
        self.assertEqual(set(updates[0]), {"InstanceId", "SecurityProfileId", "Applications"})
        associations = [call[4]["EntityArn"] for call in self.aws.writes()
                        if call[2] == "associate-security-profiles"]
        self.assertEqual(set(associations), {AGENT, AGENT + ":2"})
        for arn, previous in before.items():
            expected = previous | {"admin-id"} if arn in CONFIG["agent_arns"] else previous
            self.assertEqual(self.aws.attached[arn], expected)
        self.assertTrue(all(call[0] == "us-east-1" and call[3] == "deployment-profile" for call in self.aws.calls))
        self.assertTrue(all(call[4]["InstanceId"] == INSTANCE for call in self.aws.calls if call[1] == "connect"))

    def test_repeated_run_is_idempotent(self):
        self.grant()
        self.aws.calls.clear()
        self.grant()
        self.assertEqual(self.aws.writes(), [])

    def test_adds_missing_mcp_application(self):
        self.aws.applications = self.aws.applications[:1]
        self.grant()
        self.assertEqual(self.aws.applications[1], {
            "Namespace": CONFIG["namespace"], "Type": "MCP", "ApplicationPermissions": sorted(TOOLS),
        })

    def test_wrong_account_or_agent_scope_is_rejected_before_writes(self):
        for case in ("account", "region", "different-agent", "different-assistant"):
            with self.subTest(case=case):
                self.setUp()
                if case == "account":
                    self.aws.account = "000000000000"
                elif case == "region":
                    self.config["agent_arns"][0] = AGENT.replace("us-east-1", "us-west-2")
                elif case == "different-agent":
                    self.config["agent_arns"][0] = AGENT.replace("support-agent-id", "other-agent-id")
                else:
                    self.config["agent_arns"][0] = AGENT.replace("assistant-id", "other-assistant-id")
                with self.assertRaises((ValueError, RuntimeError)):
                    self.grant()
                self.assertEqual(self.aws.writes(), [])

    def test_unsupported_agent_qualifiers_are_rejected_before_connect_calls(self):
        for qualifier in ("$LATEST", "$SAVED", "0", "-1", "1:2", "", "\u0661"):
            with self.subTest(qualifier=qualifier):
                self.setUp()
                self.config["agent_arns"][0] = AGENT + ":" + qualifier
                with self.assertRaisesRegex(ValueError, "positive numeric version"):
                    self.grant()
                self.assertFalse(any(call[1] == "connect" for call in self.aws.calls))

    def test_malformed_agent_paths_are_rejected_before_connect_calls(self):
        prefix = AGENT.split("ai-agent/")[0] + "ai-agent/"
        for path in ("assistant-only", "assistant/", "/agent", "assistant/agent/extra"):
            with self.subTest(path=path):
                self.setUp()
                self.config["agent_arns"][0] = prefix + path
                with self.assertRaisesRegex(ValueError, "Invalid AI agent resource path"):
                    self.grant()
                self.assertFalse(any(call[1] == "connect" for call in self.aws.calls))

    def test_admin_profile_must_exist_uniquely(self):
        for profiles in ([], [{"Name": "Admin", "Id": "one"}, {"Name": "Admin", "Id": "two"}]):
            with self.subTest(profiles=profiles):
                self.setUp()
                self.aws.profiles = profiles
                with self.assertRaisesRegex(RuntimeError, "exactly one"):
                    self.grant()
                self.assertEqual(self.aws.writes(), [])

    def test_namespace_type_collision_and_duplicate_are_rejected(self):
        for duplicate in (False, True):
            with self.subTest(duplicate=duplicate):
                self.setUp()
                if duplicate:
                    self.aws.applications.append(copy.deepcopy(self.aws.applications[1]))
                else:
                    self.aws.applications[1]["Type"] = "THIRD_PARTY_APPLICATION"
                with self.assertRaises(RuntimeError):
                    self.grant()
                self.assertEqual(self.aws.writes(), [])

    def test_permission_read_failure_is_not_treated_as_no_existing_access(self):
        self.aws.fail_on = "list-security-profile-applications"
        with self.assertRaisesRegex(RuntimeError, "AccessDeniedException"):
            self.grant()
        self.assertEqual(self.aws.writes(), [])

    def test_permission_update_must_be_verified_before_associating_admin(self):
        self.aws.ignore_update = True
        with self.assertRaisesRegex(RuntimeError, "tool permissions were not verified"):
            self.grant()
        self.assertFalse(any(call[2] == "associate-security-profiles" for call in self.aws.calls))

    def test_admin_association_must_be_verified(self):
        self.aws.ignore_associate = True
        with self.assertRaisesRegex(RuntimeError, "Admin assignment was not verified"):
            self.grant()

    def test_empty_tools_are_rejected_before_writes(self):
        self.config["tool_names"] = []
        with self.assertRaisesRegex(ValueError, "tool names are required"):
            self.grant()
        self.assertEqual(self.aws.writes(), [])

    def test_cli_preserves_agent_arn_and_profile_without_a_shell(self):
        response = subprocess.CompletedProcess("aws", 0, "", "")
        with patch.object(ACCESS.subprocess, "run", return_value=response) as run:
            ACCESS.aws("us-east-1", "connect", "associate-security-profiles",
                       aws_profile="deployment-profile", EntityArn=AGENT + ":2")
        arguments = run.call_args.args[0]
        self.assertEqual(json.loads(arguments[arguments.index("--cli-input-json") + 1])["EntityArn"], AGENT + ":2")
        self.assertEqual(arguments[arguments.index("--profile") + 1], "deployment-profile")
        self.assertNotIn("shell", run.call_args.kwargs)
        self.assertNotIn("--no-paginate", arguments)


if __name__ == "__main__":
    unittest.main()
