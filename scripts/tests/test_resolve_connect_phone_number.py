import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "resolve-connect-phone-number.py"
SPEC = importlib.util.spec_from_file_location("resolve_connect_phone_number", SCRIPT)
RESOLVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RESOLVER)

INSTANCE_ID = "11111111-2222-4333-8444-555555555555"
PHONE_ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
QUERY = {
    "instance_id": INSTANCE_ID,
    "phone_number": "+18557117965",
    "region": "us-east-1",
}


def response(numbers):
    return subprocess.CompletedProcess(
        [], 0, stdout=json.dumps({"ListPhoneNumbersSummaryList": numbers}), stderr=""
    )


class ResolveConnectPhoneNumberTests(unittest.TestCase):
    def test_returns_uuid_for_exact_number_and_scopes_read_to_instance(self):
        runner = mock.Mock(return_value=response([
            {"PhoneNumber": "+18557117966", "PhoneNumberId": "not-the-selected-number"},
            {"PhoneNumber": QUERY["phone_number"], "PhoneNumberId": PHONE_ID},
        ]))
        self.assertEqual(
            RESOLVER.resolve_phone_number(QUERY, runner=runner),
            {"phone_number_id": PHONE_ID},
        )
        command = runner.call_args.args[0]
        self.assertEqual(command[:3], ["aws", "connect", "list-phone-numbers-v2"])
        self.assertEqual(command[command.index("--instance-id") + 1], INSTANCE_ID)
        self.assertEqual(command[command.index("--phone-number-prefix") + 1], QUERY["phone_number"])
        self.assertEqual(command[command.index("--region") + 1], "us-east-1")
        self.assertEqual(command[command.index("--output") + 1], "json")
        self.assertNotIn("--no-paginate", command)

    def test_missing_or_ambiguous_number_fails_instead_of_selecting_another(self):
        matching = {"PhoneNumber": QUERY["phone_number"], "PhoneNumberId": PHONE_ID}
        for numbers in [[], [matching, matching]]:
            with self.subTest(count=len(numbers)):
                with self.assertRaisesRegex(ValueError, "Expected one claimed number"):
                    RESOLVER.resolve_phone_number(QUERY, runner=mock.Mock(return_value=response(numbers)))

    def test_invalid_inputs_do_not_call_aws(self):
        for key, value in [
            ("instance_id", "not-a-uuid"),
            ("phone_number", "+1 855-711-7965"),
            ("phone_number", "18557117965"),
            ("region", "invalid-region"),
        ]:
            with self.subTest(key=key, value=value):
                runner = mock.Mock()
                with self.assertRaises(ValueError):
                    RESOLVER.resolve_phone_number({**QUERY, key: value}, runner=runner)
                runner.assert_not_called()

    def test_aws_authentication_errors_are_reported(self):
        runner = mock.Mock(return_value=subprocess.CompletedProcess(
            [], 1, stdout="", stderr="InvalidClientTokenId: token is invalid"
        ))
        with self.assertRaisesRegex(RuntimeError, "InvalidClientTokenId"):
            RESOLVER.resolve_phone_number(QUERY, runner=runner)

    def test_invalid_uuid_from_aws_is_rejected(self):
        runner = mock.Mock(return_value=response([
            {"PhoneNumber": QUERY["phone_number"], "PhoneNumberId": "+18557117965"},
        ]))
        with self.assertRaisesRegex(ValueError, "invalid phone-number resource UUID"):
            RESOLVER.resolve_phone_number(QUERY, runner=runner)

    def test_external_data_protocol_prints_only_json(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(RESOLVER.sys, "stdin", io.StringIO(json.dumps(QUERY))), \
                mock.patch.object(RESOLVER, "resolve_phone_number", return_value={"phone_number_id": PHONE_ID}), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(RESOLVER.main(), 0)
        self.assertEqual(json.loads(stdout.getvalue()), {"phone_number_id": PHONE_ID})
        self.assertEqual(stderr.getvalue(), "")

    def test_external_data_protocol_reports_errors_on_stderr(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(RESOLVER.sys, "stdin", io.StringIO(json.dumps(QUERY))), \
                mock.patch.object(RESOLVER, "resolve_phone_number", side_effect=ValueError("number not claimed")), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(RESOLVER.main(), 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("number not claimed", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
