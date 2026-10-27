import importlib
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from zipfile import ZipFile


SOURCE = Path(__file__).resolve().parents[1] / "src"


def invocation():
    return {"Details": {"Parameters": {
        "email": "caller@example.com",
        "reason": "Caller needs help connecting to the corporate VPN.",
    }}}


class NextthinkWarmupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        archive = Path(temporary.name) / "nextthink.zip"
        # Import the real handler and wrapper from the deployment ZIP layout.
        with ZipFile(archive, "w") as package:
            for name in ("lambda_function.py", "warmup_wrapper.py"):
                package.write(SOURCE / name, name)
        self.secrets = Mock()
        self.secrets.get_secret_value.return_value = {
            "SecretString": json.dumps({
                "clientId": "test-client", "clientSecret": "test-secret",
            })
        }
        self.http = Mock()
        for temporary_patch in (
            patch.dict(sys.modules),
            patch.dict(os.environ, {
                "ORIGINAL_HANDLER": "lambda_function.lambda_handler",
                "NEXTHINK_SECRET_NAME": "test/nexthink",
                "NEXTHINK_TOKEN_SCOPE": "service:integration",
                "TOKEN_REFRESH_BUFFER_SECONDS": "60",
            }),
            patch.object(sys, "path", [str(archive), *sys.path]),
            patch("boto3.client", return_value=self.secrets),
            patch("urllib3.PoolManager", return_value=self.http),
        ):
            temporary_patch.start()
            self.addCleanup(temporary_patch.stop)
        sys.modules.pop("lambda_function", None)
        sys.modules.pop("warmup_wrapper", None)
        self.wrapper = importlib.import_module("warmup_wrapper")
        self.business = sys.modules["lambda_function"]

    def successful_responses(self, handoffs=1):
        token = SimpleNamespace(status=200, data=json.dumps({
            "access_token": "test-access-token", "token_type": "Bearer",
            "expires_in": 900, "scope": "service:integration",
        }).encode("utf-8"))
        self.http.request.side_effect = [token] + [
            SimpleNamespace(status=200, data=b"{}") for _ in range(handoffs)
        ]

    def test_warmup_skips_secrets_authentication_and_handoff(self):
        self.assertEqual(self.wrapper.handler({"warmup": True}, None), {
            "Status": "Success", "Message": "warm",
        })
        self.secrets.get_secret_value.assert_not_called()
        self.http.request.assert_not_called()
        self.assertIsNone(self.business._cached_access_token)

    def test_other_events_delegate_unchanged(self):
        response, context = object(), object()
        with patch.object(self.wrapper, "_original_handler", return_value=response) as original:
            for event in (None, [], {}, {"warmup": False}, {"warmup": "true"},
                          {"warmup": 1}, invocation()):
                with self.subTest(event=event):
                    original.reset_mock()
                    self.assertIs(self.wrapper.handler(event, context), response)
                    original.assert_called_once_with(event, context)

    def test_zip_entry_point_reaches_existing_handoff_implementation(self):
        self.successful_responses()
        self.assertIs(self.wrapper._original_handler, self.business.lambda_handler)
        result = self.wrapper.handler(invocation(), None)
        self.assertEqual(result["Status"], "success")
        self.assertEqual(result["NextAction"], "Disconnect")
        self.assertEqual(result["NexthinkStatusCode"], "200")
        self.secrets.get_secret_value.assert_called_once_with(SecretId="test/nexthink")
        self.assertEqual(self.http.request.call_count, 2)
        self.assertEqual(self.http.request.call_args_list[0].kwargs["url"], self.business.TOKEN_URL)
        self.assertEqual(self.http.request.call_args_list[1].kwargs["url"], self.business.HANDOFF_URL)

    def test_warmup_preserves_cached_token_between_business_calls(self):
        self.successful_responses(handoffs=2)
        self.wrapper.handler(invocation(), None)
        self.assertEqual(self.business._cached_access_token, "test-access-token")
        self.wrapper.handler({"warmup": True}, None)
        self.assertEqual(self.http.request.call_count, 2)
        self.assertEqual(self.business._cached_access_token, "test-access-token")
        result = self.wrapper.handler(invocation(), None)
        self.assertEqual(result["Status"], "success")
        self.secrets.get_secret_value.assert_called_once()
        self.assertEqual(self.http.request.call_count, 3)

    def test_normal_invalid_input_keeps_existing_error_response(self):
        result = self.wrapper.handler({"Details": {"Parameters": {"reason": "test"}}}, None)
        self.assertEqual(result["Status"], "Failure")
        self.assertEqual(result["NextAction"], "Escalate")
        self.secrets.get_secret_value.assert_not_called()
        self.http.request.assert_not_called()


if __name__ == "__main__":
    unittest.main()
