import importlib
import os
from pathlib import Path
import sys
import tempfile
from types import ModuleType
import unittest
from unittest.mock import Mock, patch
from zipfile import ZipFile


SOURCE = Path(__file__).resolve().parents[1] / "src"


class SnowWarmupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        archive = Path(temporary.name) / "snow.zip"
        # Exercise imports from a ZIP with the same root layout as source_dir.
        with ZipFile(archive, "w") as package:
            for name in ("lambda_function.py", "warmup_wrapper.py"):
                package.write(SOURCE / name, name)

        self.secrets = Mock()
        self.secrets.get_secret_value.return_value = {
            "SecretString": '{"username": "test-user", "password": "test-password"}'
        }
        boto3 = ModuleType("boto3")
        boto3.client = Mock(return_value=self.secrets)

        for temporary_patch in (
            patch.dict(sys.modules, {"boto3": boto3}),
            patch.dict(os.environ, {
                "ORIGINAL_HANDLER": "lambda_function.lambda_handler",
                "SN_SECRET_USERNAME_KEY": "username",
                "SN_SECRET_PASSWORD_KEY": "password",
                "LOG_RAW_EVENT": "false",
                "REQUIRE_ACTIVE_USER": "false",
                "REJECT_LOCKED_OUT_USER": "false",
                "AUTH_REQUIRED_FIELDS": "sys_id",
            }),
            patch.object(sys, "path", [str(archive), *sys.path]),
        ):
            temporary_patch.start()
            self.addCleanup(temporary_patch.stop)
        sys.modules.pop("lambda_function", None)
        sys.modules.pop("warmup_wrapper", None)
        self.wrapper = importlib.import_module("warmup_wrapper")
        self.service = sys.modules["lambda_function"]
        self.secrets.reset_mock()

    def test_zip_entry_point_resolves_attached_servicenow_handler(self):
        self.assertIs(self.wrapper._original_handler, self.service.lambda_handler)
        self.assertIs(self.service.handler, self.service.lambda_handler)
        self.assertEqual(self.service.BUILD, "userlookup-v10.1")

    def test_warmup_skips_servicenow_lookup(self):
        with patch.object(self.service, "_query_users") as query:
            self.assertEqual(self.wrapper.handler({"warmup": True}, None), {
                "Status": "Success", "Message": "warm",
            })
            query.assert_not_called()
        self.secrets.get_secret_value.assert_not_called()

    def test_other_events_delegate_unchanged(self):
        response, context = object(), object()
        with patch.object(self.wrapper, "_original_handler", return_value=response) as original:
            for event in (None, [], {}, {"warmup": False}, {"warmup": "true"}, {"warmup": 1}):
                with self.subTest(event=event):
                    original.reset_mock()
                    self.assertIs(self.wrapper.handler(event, context), response)
                    original.assert_called_once_with(event, context)

    def test_contact_flow_phone_lookup_reaches_servicenow_implementation(self):
        record = {
            "sys_id": "test-sys-id", "first_name": "Alice", "last_name": "Example",
            "phone": "+15551234567", "employee_number": "test-upi",
        }
        event = {"Details": {
            "Parameters": {},
            "ContactData": {
                "ContactId": "test-contact",
                "CustomerEndpoint": {"Address": "+15551234567"},
            },
        }}
        with patch.object(self.service, "_query_users", return_value=[record]) as query:
            result = self.wrapper.handler(event, None)
            query.assert_called_once()
        self.assertEqual(result["PhoneLookupStatus"], "Matched")
        self.assertEqual(result["Status"], "Authenticated")
        self.assertEqual(result["RegisteredCaller"], "Yes")
        self.assertEqual(result["FirstName"], "Alice")
        self.assertEqual(set(result), set(self.service.CF_KEYS))
        self.assertTrue(all(isinstance(value, str) for value in result.values()))

    def test_original_handler_exceptions_propagate(self):
        with patch.object(self.wrapper, "_original_handler", side_effect=RuntimeError("lookup failed")):
            with self.assertRaisesRegex(RuntimeError, "lookup failed"):
                self.wrapper.handler({}, None)


if __name__ == "__main__":
    unittest.main()
