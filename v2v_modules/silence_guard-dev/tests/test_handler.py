import importlib
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile


SOURCE = Path(__file__).resolve().parents[1] / "src"


def invocation(**overrides):
    parameters = {
        "ExpectedTool": "Complete",
        "Tool": "Complete",
        "Intent": "Password Reset - PingID Re-enable",
        "CallSummary": "Caller completed the requested password reset assistance.",
        "VerificationStatus": "Authenticated",
        "VerifiedVia": "Phone",
        "RoutingIntent": "",
        "region": "US",
    }
    parameters.update(overrides)
    return {"Details": {"Parameters": parameters}}


class SilenceGuardTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        archive = Path(temporary.name) / "silence_guard.zip"
        # Import the real files from the ZIP root, matching Terraform source_dir.
        with ZipFile(archive, "w") as package:
            for name in ("lambda_function.py", "warmup_wrapper.py"):
                package.write(SOURCE / name, name)
        for temporary_patch in (
            patch.dict(sys.modules),
            patch.dict(os.environ, {
                "ORIGINAL_HANDLER": "lambda_function.lambda_handler",
                "STRICT_MODE": "false",
            }),
            patch.object(sys, "path", [str(archive), *sys.path]),
        ):
            temporary_patch.start()
            self.addCleanup(temporary_patch.stop)
        sys.modules.pop("lambda_function", None)
        sys.modules.pop("warmup_wrapper", None)
        self.wrapper = importlib.import_module("warmup_wrapper")
        self.guard = sys.modules["lambda_function"]

    def test_zip_entry_point_resolves_original_guard(self):
        self.assertIs(self.wrapper._original_handler, self.guard.lambda_handler)

    def test_warmup_skips_guard_business_logic(self):
        with patch.object(self.guard, "_check") as check:
            self.assertEqual(self.wrapper.handler({"warmup": True}, None), {
                "Status": "Success", "Message": "warm",
            })
            check.assert_not_called()

    def test_other_events_delegate_unchanged(self):
        response, context = object(), object()
        with patch.object(self.wrapper, "_original_handler", return_value=response) as original:
            for event in (None, [], {}, {"warmup": False}, {"warmup": "true"},
                          {"warmup": 1}, invocation()):
                with self.subTest(event=event):
                    original.reset_mock()
                    self.assertIs(self.wrapper.handler(event, context), response)
                    original.assert_called_once_with(event, context)

    def test_v13_normalizes_pingid_reenable_label_in_strict_mode(self):
        with patch.object(self.guard, "STRICT_MODE", True):
            for intent in (
                "Password Reset - PingID Re-enable",
                "password reset - pingid re-enable",
                " Password Reset \u2013 PingID Re-enable ",
            ):
                with self.subTest(intent=intent):
                    self.assertEqual(self.wrapper.handler(invocation(Intent=intent), None), {
                        "GuardAllowed": "true",
                        "GuardReason": "ok",
                        "NormalizedIntent": "Password Reset - PingID Re-enable",
                    })

    def test_advisory_mode_reports_issues_without_blocking(self):
        result = self.wrapper.handler(invocation(
            Intent="not a known intent", Tool="Escalate", CallSummary="short",
        ), None)
        self.assertEqual(result["GuardAllowed"], "true")
        self.assertEqual(set(result["GuardReason"].split(",")), {
            "tool_mismatch", "intent_unknown", "summary_short",
        })

    def test_supplied_close_only_labels_allow_complete_and_block_escalate_in_strict_mode(self):
        with patch.object(self.guard, "STRICT_MODE", True):
            for intent in (
                "Out of Scope - Medical Request",
                "Out of Scope - Unverified/WrongNumber Misroute",
                "Unverified - Verification Failed",
            ):
                with self.subTest(intent=intent):
                    complete = self.wrapper.handler(invocation(Intent=intent), None)
                    self.assertEqual(complete["GuardReason"], "ok")
                    self.assertEqual(complete["GuardAllowed"], "true")
                    escalate = self.wrapper.handler(invocation(
                        Intent=intent, ExpectedTool="Escalate", Tool="Escalate",
                    ), None)
                    self.assertEqual(escalate["GuardAllowed"], "false")
                    self.assertIn("close_only_intent_on_escalate", escalate["GuardReason"])

    def test_inconsistent_routing_is_reported_in_advisory_mode(self):
        for routing, expected_reason in (
            ("HR", "routing_intent_label_mismatch"),
            ("FieldForce", "fieldforce_unverified"),
            ("Veeva", "veeva_medcom_outside_latam"),
            ("Medcom", "routing_intent_label_mismatch"),
        ):
            with self.subTest(routing=routing):
                result = self.wrapper.handler(invocation(
                    ExpectedTool="Escalate", Tool="Escalate", RoutingIntent=routing,
                    VerificationStatus="Unauthenticated",
                ), None)
                self.assertEqual(result["GuardAllowed"], "true")
                self.assertIn(expected_reason, result["GuardReason"].split(","))

    def test_consistent_routing_is_allowed_in_strict_mode(self):
        with patch.object(self.guard, "STRICT_MODE", True):
            for routing, intent, region in (
                ("HR", "HR - Payroll", "US"),
                ("FieldForce", "Field Force - Direct Routing", "US"),
                ("Veeva", "Veeva - LATAM Helpdesk", "LATAM"),
                ("Medcom", "Medcom - LATAM Helpdesk", "LATAM"),
            ):
                with self.subTest(routing=routing):
                    result = self.wrapper.handler(invocation(
                        ExpectedTool="Escalate", Tool="Escalate", RoutingIntent=routing,
                        Intent=intent, region=region,
                    ), None)
                    self.assertEqual(result["GuardAllowed"], "true")
                    self.assertEqual(result["GuardReason"], "ok")

    def test_internal_guard_errors_fail_open_even_in_strict_mode(self):
        with patch.object(self.guard, "STRICT_MODE", True), patch.object(
            self.guard, "_check", side_effect=RuntimeError("test guard failure")
        ):
            result = self.wrapper.handler(invocation(), None)
        self.assertEqual(result, {
            "GuardAllowed": "true",
            "GuardReason": "guard_error:RuntimeError",
            "NormalizedIntent": "",
        })


if __name__ == "__main__":
    unittest.main()
