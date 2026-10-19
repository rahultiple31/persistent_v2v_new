import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch
from xml.etree import ElementTree
from zipfile import ZipFile


SOURCE = (
    Path(__file__).resolve().parents[3]
    / "environments/dev/metadata/BTSGSD-lex-QueueFlow-Callback-dev_lambda/lambda_function.py"
)
spec = importlib.util.spec_from_file_location("lex_queue_callback_handler", SOURCE)
handler = importlib.util.module_from_spec(spec)
with patch.dict(os.environ, {"LOG_LEVEL": "INFO"}):
    spec.loader.exec_module(handler)


def invocation(intent="FallbackIntent", transcript="", attributes=None):
    return {
        "sessionId": "contact-123",
        "bot": {"localeId": "en_US"},
        "inputTranscript": transcript,
        "sessionState": {
            "sessionAttributes": attributes or {},
            "intent": {"name": intent, "confirmationState": "None"},
        },
    }


class HandlerTests(unittest.TestCase):
    def test_zip_contains_the_current_source_at_root(self):
        with ZipFile(SOURCE.with_suffix(".zip")) as package:
            self.assertEqual(package.namelist(), ["lambda_function.py"])
            self.assertEqual(package.read("lambda_function.py"), SOURCE.read_bytes())

    def assert_lex_response(self, response):
        attributes = response["sessionState"]["sessionAttributes"]
        self.assertTrue(all(isinstance(value, str) for value in attributes.values()))
        for message in response["messages"]:
            self.assertEqual(message["contentType"], "SSML")
            self.assertEqual(ElementTree.fromstring(message["content"]).tag, "speak")
        if response["sessionState"]["dialogAction"]["type"] == "Close":
            intent = response["sessionState"]["intent"]
            self.assertEqual(intent["state"], "Fulfilled")
            self.assertEqual(intent["confirmationState"], "None")
            self.assertNotIn("confirmationStatus", intent)

    def test_success_intents_return_existing_flow_values(self):
        for intent, confirmation in (
            ("voicemail", "voicemail_confirmation"),
            ("virtualQueue", "virtualQueue_confirmation"),
            ("repeat", "repeat_confimation"),
        ):
            with self.subTest(intent=intent):
                response = handler.lambda_handler(invocation(intent), None)
                self.assert_lex_response(response)
                self.assertEqual(response["sessionState"]["dialogAction"]["type"], "Close")
                self.assertEqual(response["sessionState"]["intent"]["name"], intent)
                self.assertEqual(response["sessionState"]["sessionAttributes"]["confirmation"], confirmation)
                self.assertEqual(response["sessionState"]["sessionAttributes"][f"{intent}_count"], "1")

    def test_timeout_prompts_twice_then_closes(self):
        attributes = {}
        for count, action in ((1, "ElicitIntent"), (2, "ElicitIntent"), (3, "Close")):
            response = handler.lambda_handler(invocation(attributes=attributes), None)
            self.assert_lex_response(response)
            self.assertEqual(response["sessionState"]["dialogAction"]["type"], action)
            attributes = response["sessionState"]["sessionAttributes"]
            self.assertEqual(attributes["timeout_count"], str(count))

    def test_retry_prompts_twice_then_closes(self):
        attributes = {}
        for count, action in ((1, "ElicitIntent"), (2, "ElicitIntent"), (3, "Close")):
            response = handler.lambda_handler(invocation(transcript="unknown", attributes=attributes), None)
            self.assert_lex_response(response)
            self.assertEqual(response["sessionState"]["dialogAction"]["type"], action)
            attributes = response["sessionState"]["sessionAttributes"]
            self.assertEqual(attributes["retry_count"], str(count))

    def test_combined_timeout_and_retry_budget_is_three(self):
        response = handler.lambda_handler(invocation(attributes={"timeout_count": "1", "retry_count": "1"}), None)
        self.assert_lex_response(response)
        self.assertEqual(response["sessionState"]["dialogAction"]["type"], "Close")

    def test_partial_session_attributes_keep_custom_prompt_and_fill_defaults(self):
        response = handler.lambda_handler(invocation(attributes={"menu_prompt": "Choose callback or voicemail"}), None)
        self.assert_lex_response(response)
        self.assertIn("Choose callback or voicemail", response["messages"][0]["content"])
        self.assertEqual(response["sessionState"]["sessionAttributes"]["timeout_count"], "1")

    def test_warm_invocations_do_not_leak_session_state(self):
        handler.lambda_handler(invocation(attributes={"menu_prompt": "Private prompt", "retry_count": "2"}), None)
        response = handler.lambda_handler(invocation(), None)
        self.assert_lex_response(response)
        self.assertEqual(response["sessionState"]["sessionAttributes"]["menu_prompt"], "Please confirm")
        self.assertEqual(response["sessionState"]["sessionAttributes"]["retry_count"], "0")

    def test_ssml_existing_wrapper_is_not_nested(self):
        message = handler.make_ssml("<speak>Please confirm</speak>")
        root = ElementTree.fromstring(message["content"])
        self.assertEqual(root.tag, "speak")
        self.assertEqual(list(root), [])
        self.assertEqual(root.text.strip(), "Please confirm")


if __name__ == "__main__":
    unittest.main()
