import importlib.util
import pathlib
import subprocess
import sys
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "check_capacity", pathlib.Path(__file__).parents[1] / "scripts" / "check_capacity.py"
)
capacity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capacity)


class CapacityTest(unittest.TestCase):
    query = {"region": "us-east-1", "account_id": "518902362956", "function_name": "BTSGSD-V2V-US-SNOW_btsgsd-dev"}

    def result_for(self, unreserved, concurrency):
        responses = [
            {"Account": self.query["account_id"]},
            {"AccountLimit": {"UnreservedConcurrentExecutions": unreserved}},
            concurrency,
        ]
        with patch.object(capacity, "aws_json", side_effect=responses):
            return capacity.check_capacity(self.query)

    def test_new_function_boundary(self):
        missing = capacity.AwsCliError("An error occurred (ResourceNotFoundException)")
        self.assertEqual(self.result_for(400, missing)["maximum_reservation"], "300")
        self.assertEqual(self.result_for(399, missing)["maximum_reservation"], "299")

    def test_existing_reservation_is_reusable(self):
        result = self.result_for(100, {"ReservedConcurrentExecutions": 300})
        self.assertEqual(result["maximum_reservation"], "300")

    def test_existing_unreserved_function(self):
        self.assertEqual(self.result_for(400, {})["maximum_reservation"], "300")

    def test_access_denied_is_not_treated_as_missing_function(self):
        with self.assertRaises(capacity.AwsCliError):
            self.result_for(400, capacity.AwsCliError("An error occurred (AccessDeniedException)"))

    def test_wrong_account_is_rejected(self):
        with patch.object(capacity, "aws_json", return_value={"Account": "000000000000"}):
            with self.assertRaisesRegex(RuntimeError, "same AWS account"):
                capacity.check_capacity(self.query)


class AwsJsonTest(unittest.TestCase):
    def response(self, stdout="", stderr="", returncode=0):
        return subprocess.CompletedProcess("aws", returncode, stdout, stderr)

    def test_empty_concurrency_response_preserves_capacity_calculation(self):
        responses = [
            self.response('{"Account":"518902362956"}'),
            self.response('{"AccountLimit":{"UnreservedConcurrentExecutions":350}}'),
            self.response(" \n"),
        ]
        with patch.object(capacity.subprocess, "run", side_effect=responses):
            result = capacity.check_capacity(CapacityTest.query)
        self.assertEqual(result, {
            "unreserved": "350",
            "current_reservation": "0",
            "maximum_reservation": "250",
        })

    def test_valid_json_is_preserved(self):
        with patch.object(capacity.subprocess, "run", return_value=self.response(
            '{"ReservedConcurrentExecutions":200}'
        )):
            result = capacity.aws_json("us-east-1", "lambda", "get-function-concurrency")
        self.assertEqual(result, {"ReservedConcurrentExecutions": 200})

    def test_empty_identity_or_account_settings_response_fails(self):
        for arguments in (("sts", "get-caller-identity"), ("lambda", "get-account-settings")):
            with self.subTest(arguments=arguments):
                with patch.object(capacity.subprocess, "run", return_value=self.response()):
                    with self.assertRaisesRegex(capacity.AwsCliError, "returned empty output"):
                        capacity.aws_json("us-east-1", *arguments)

    def test_invalid_json_identifies_command_without_echoing_response(self):
        with patch.object(capacity.subprocess, "run", return_value=self.response("invalid-body")):
            with self.assertRaisesRegex(
                capacity.AwsCliError, "lambda get-function-concurrency returned invalid JSON"
            ) as error:
                capacity.aws_json("us-east-1", "lambda", "get-function-concurrency")
        self.assertNotIn("invalid-body", str(error.exception))

    def test_non_object_json_is_rejected(self):
        for output in ("null", "[]", '"text"', "200"):
            with self.subTest(output=output):
                with patch.object(capacity.subprocess, "run", return_value=self.response(output)):
                    with self.assertRaisesRegex(capacity.AwsCliError, "unexpected JSON type"):
                        capacity.aws_json("us-east-1", "lambda", "get-function-concurrency")

    def test_cli_failure_is_not_treated_as_empty_concurrency(self):
        with patch.object(capacity.subprocess, "run", return_value=self.response(
            stderr="An error occurred (AccessDeniedException)", returncode=1
        )):
            with self.assertRaisesRegex(capacity.AwsCliError, "AccessDeniedException"):
                capacity.aws_json("us-east-1", "lambda", "get-function-concurrency")

    def test_cli_failure_without_stderr_has_context(self):
        with patch.object(capacity.subprocess, "run", return_value=self.response(returncode=1)):
            with self.assertRaisesRegex(
                capacity.AwsCliError, "sts get-caller-identity failed: No error details"
            ):
                capacity.aws_json("us-east-1", "sts", "get-caller-identity")


class InputContractTest(unittest.TestCase):
    def test_invalid_terraform_input_fails_with_stderr_only(self):
        for input_value, expected in (
            ("", "Terraform supplied empty or invalid JSON"),
            ("invalid", "Terraform supplied empty or invalid JSON"),
            ("[]", "Terraform capacity-check input must be a JSON object"),
        ):
            with self.subTest(input_value=input_value):
                result = subprocess.run(
                    [sys.executable, str(spec.origin)],
                    input=input_value,
                    capture_output=True,
                    text=True,
                    timeout=10,
                    check=False,
                )
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, "")
                self.assertIn(expected, result.stderr)
                self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
