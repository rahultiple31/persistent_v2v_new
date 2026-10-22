import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import Mock, patch
from zipfile import ZipFile

from botocore.exceptions import ClientError, EndpointConnectionError, ParamValidationError


SOURCE = (
    Path(__file__).resolve().parents[3]
    / "environments/v2v/metadata/scr_lambda/lambda_function.py"
)
spec = importlib.util.spec_from_file_location("session_attributes_handler", SOURCE)
handler = importlib.util.module_from_spec(spec)
with patch("boto3.client"), patch.dict(os.environ, {"NAMESPACE": "Custom", "LOG_LEVEL": "INFO"}):
    spec.loader.exec_module(handler)

INSTANCE_ARN = "arn:aws:connect:us-east-1:123456789012:instance/instance-id"
SESSION_ARN = "arn:aws:wisdom:us-east-1:123456789012:session/assistant-id/session-id"


def invocation(parameters):
    return {"Details": {
        "ContactData": {"InstanceARN": INSTANCE_ARN, "ContactId": "contact-id"},
        "Parameters": parameters,
    }}


class HandlerTests(unittest.TestCase):
    def setUp(self):
        self.connect = Mock()
        self.qconnect = Mock()
        self.connect.describe_contact.return_value = {
            "Contact": {"WisdomInfo": {"SessionArn": SESSION_ARN}}
        }
        clients = patch.multiple(handler, _connect=self.connect, _qconnect=self.qconnect)
        clients.start()
        self.addCleanup(clients.stop)

    def test_updates_contact_session_and_normalizes_values(self):
        response = handler.handler(invocation({
            "Name": " Alice ", "Count": 0, "Long": "x" * 5000,
            "Empty": " ", "Missing": None,
        }), None)

        self.assertEqual(response, {"status": "success", "keysSet": "Name,Count,Long"})
        self.connect.describe_contact.assert_called_once_with(
            InstanceId=INSTANCE_ARN, ContactId="contact-id",
        )
        self.qconnect.update_session_data.assert_called_once_with(
            assistantId="assistant-id", sessionId="session-id", namespace="Custom",
            data=[
                {"key": "Name", "value": {"stringValue": "Alice"}},
                {"key": "Count", "value": {"stringValue": "0"}},
                {"key": "Long", "value": {"stringValue": "x" * 4096}},
            ],
        )

    def test_empty_parameters_skip_aws_calls(self):
        for parameters in ({}, None, {"Empty": "", "Missing": None}):
            with self.subTest(parameters=parameters):
                self.assertEqual(handler.handler(invocation(parameters), None), {
                    "status": "success", "keysSet": "",
                })
        self.connect.describe_contact.assert_not_called()
        self.qconnect.update_session_data.assert_not_called()

    def test_malformed_events_are_rejected_before_aws_calls(self):
        events = [None, {}, {"Details": None}, {"Details": {"ContactData": []}},
                  invocation(["invalid"]), invocation("invalid")]
        for field, value in (("InstanceARN", ""), ("ContactId", None)):
            event = invocation({"Name": "Alice"})
            event["Details"]["ContactData"][field] = value
            events.append(event)
        for event in events:
            with self.subTest(event=event):
                self.assertEqual(handler.handler(event, None), {
                    "status": "error", "errorCode": "InvalidEvent",
                })
        self.connect.describe_contact.assert_not_called()
        self.qconnect.update_session_data.assert_not_called()

    def test_missing_session_returns_flow_error(self):
        for contact in ({}, None, {"WisdomInfo": None}):
            with self.subTest(contact=contact):
                self.connect.describe_contact.return_value = {"Contact": contact}
                self.assertEqual(handler.handler(invocation({"Name": "Alice"}), None), {
                    "status": "error", "errorCode": "RuntimeError",
                })
        self.qconnect.update_session_data.assert_not_called()

    def test_malformed_session_arn_is_not_sent(self):
        self.connect.describe_contact.return_value = {
            "Contact": {"WisdomInfo": {"SessionArn": SESSION_ARN + "/extra"}}
        }
        self.assertEqual(handler.handler(invocation({"Name": "Alice"}), None), {
            "status": "error", "errorCode": "ValueError",
        })
        self.qconnect.update_session_data.assert_not_called()

    def test_aws_errors_return_contact_flow_error_codes(self):
        errors = [
            (ClientError({"Error": {"Code": "AccessDeniedException"}}, "UpdateSessionData"),
             "AccessDeniedException"),
            (ParamValidationError(report="invalid data"), "ParamValidationError"),
            (EndpointConnectionError(endpoint_url="https://example.invalid"),
             "EndpointConnectionError"),
        ]
        for error, code in errors:
            with self.subTest(code=code):
                self.qconnect.update_session_data.side_effect = error
                self.assertEqual(handler.handler(invocation({"Name": "Alice"}), None), {
                    "status": "error", "errorCode": code,
                })

    def test_describe_contact_failure_does_not_update_session(self):
        self.connect.describe_contact.side_effect = ClientError(
            {"Error": {"Code": "ResourceNotFoundException"}}, "DescribeContact",
        )
        self.assertEqual(handler.handler(invocation({"Name": "Alice"}), None), {
            "status": "error", "errorCode": "ResourceNotFoundException",
        })
        self.qconnect.update_session_data.assert_not_called()

    def test_deployment_zip_contains_current_handler_at_root(self):
        with ZipFile(SOURCE.with_suffix(".zip")) as package:
            self.assertEqual(package.namelist(), ["lambda_function.py"])
            self.assertEqual(package.read("lambda_function.py"), SOURCE.read_bytes())


if __name__ == "__main__":
    unittest.main()
