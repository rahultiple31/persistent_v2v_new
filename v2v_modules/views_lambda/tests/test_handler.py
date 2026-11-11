import importlib
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import MagicMock, patch

SOURCE = Path(__file__).resolve().parents[1] / "src"
INSTANCE_ID = "11111111-2222-3333-4444-555555555555"


def load(name, environment):
    """Import a handler module fresh, with boto3 stubbed and the given environment."""
    boto3 = MagicMock()
    stubs = {"boto3": boto3, "botocore": MagicMock(), "botocore.config": MagicMock()}
    sys.modules.pop(name, None)
    with patch.dict(sys.modules, stubs), patch.dict(os.environ, environment, clear=True):
        sys.path.insert(0, str(SOURCE))
        try:
            module = importlib.import_module(name)
        finally:
            sys.path.remove(str(SOURCE))
    return module, boto3.client.return_value


def event(contact_id="contact-1", in_parameters=True):
    if in_parameters:
        return {"Details": {"Parameters": {"contactId": contact_id}}}
    return {"Details": {"ContactData": {"ContactId": contact_id}}}


class ViewsHandlerTests(unittest.TestCase):
    def setUp(self):
        self.module, self.connect = load(
            "lambda_function", {"CONNECT_INSTANCE_ID": INSTANCE_ID, "POLL_SLEEP": "0.5"}
        )

    def call(self, contact, request=None):
        self.connect.describe_contact.return_value = {"Contact": contact}
        with patch.object(self.module.time, "sleep") as sleep:
            result = self.module.lambda_handler(request or event(), None)
        return result, sleep

    def test_connected_contact_returns_connected_without_waiting(self):
        result, sleep = self.call({"AgentInfo": {"ConnectedToAgentTimestamp": "2026-11-11T00:00:00Z"}})
        self.assertEqual(result, {"state": "connected"})
        sleep.assert_not_called()

    def test_disconnected_contact_returns_ended_even_if_it_had_an_agent(self):
        result, sleep = self.call({
            "DisconnectTimestamp": "2026-11-11T00:01:00Z",
            "AgentInfo": {"ConnectedToAgentTimestamp": "2026-11-11T00:00:00Z"},
        })
        self.assertEqual(result, {"state": "ended"})
        sleep.assert_not_called()

    def test_waiting_contact_returns_connecting_after_the_poll_sleep(self):
        result, sleep = self.call({})
        self.assertEqual(result, {"state": "connecting"})
        sleep.assert_called_once_with(0.5)

    def test_describe_contact_uses_the_configured_instance_and_contact(self):
        self.call({}, event("abc-123"))
        self.connect.describe_contact.assert_called_once_with(InstanceId=INSTANCE_ID, ContactId="abc-123")

    def test_contact_id_falls_back_to_contact_data(self):
        self.call({}, event("from-contact-data", in_parameters=False))
        self.assertEqual(self.connect.describe_contact.call_args.kwargs["ContactId"], "from-contact-data")

    def test_api_error_is_reported_as_connecting_and_does_not_raise(self):
        self.connect.describe_contact.side_effect = RuntimeError("throttled")
        with patch.object(self.module.time, "sleep") as sleep:
            result = self.module.lambda_handler(event(), None)
        self.assertEqual(result, {"state": "connecting"})
        sleep.assert_called_once()

    def test_poll_sleep_defaults_to_four_seconds(self):
        module, _ = load("lambda_function", {"CONNECT_INSTANCE_ID": INSTANCE_ID})
        self.assertEqual(module.POLL_SLEEP, 4.0)

    def test_instance_id_is_required(self):
        with self.assertRaises(KeyError):
            load("lambda_function", {})


class WarmupWrapperTests(unittest.TestCase):
    def wrapper(self):
        calls = []
        fake = MagicMock()
        fake.lambda_handler = lambda request, context: calls.append(request) or {"state": "real"}
        with patch.dict(sys.modules, {"fake_original": fake}), patch.dict(
            os.environ, {"ORIGINAL_HANDLER": "fake_original.lambda_handler"}, clear=True
        ):
            sys.modules.pop("warmup_wrapper", None)
            sys.path.insert(0, str(SOURCE))
            try:
                module = importlib.import_module("warmup_wrapper")
            finally:
                sys.path.remove(str(SOURCE))
        return module, calls

    def test_warmup_event_skips_the_business_logic(self):
        module, calls = self.wrapper()
        self.assertEqual(module.handler({"warmup": True}, None), {"warmup": True, "status": "ok"})
        self.assertEqual(calls, [])

    def test_other_events_reach_the_original_handler(self):
        module, calls = self.wrapper()
        request = event()
        self.assertEqual(module.handler(request, None), {"state": "real"})
        self.assertEqual(calls, [request])
        self.assertEqual(module.handler({"warmup": False}, None), {"state": "real"})


if __name__ == "__main__":
    unittest.main()
