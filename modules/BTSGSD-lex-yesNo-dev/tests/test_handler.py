import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch
from zipfile import ZipFile


SOURCE = (
    Path(__file__).resolve().parents[3]
    / "environments/dev/metadata/BTSGSD-lex-yesNo-dev_lambda/lambda_function.py"
)
spec = importlib.util.spec_from_file_location("lex_yesno_handler", SOURCE)
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
    def test_yes_no_and_repeat_preserve_confirmation_values(self):
        for intent, expected in (("yes", "yes_confirmation"), ("no", "no_confirmation"),
                                 ("repeat", "repeat_confimation")):
            with self.subTest(intent=intent):
                response = handler.lambda_handler(invocation(intent), None)
                self.assertEqual(response["sessionState"]["dialogAction"]["type"], "Close")
                self.assertEqual(response["sessionState"]["sessionAttributes"]["confirmation"], expected)

    def test_dtmf_one_and_two_choose_yes_and_no(self):
        for digit, expected in (("1", "yes_confirmation"), ("2", "no_confirmation")):
            with self.subTest(digit=digit):
                response = handler.lambda_handler(invocation("dtmf", digit), None)
                self.assertEqual(response["sessionState"]["sessionAttributes"]["confirmation"], expected)

    def test_invalid_dtmf_reprompts(self):
        response = handler.lambda_handler(invocation("dtmf", "9"), None)
        self.assertEqual(response["sessionState"]["dialogAction"]["type"], "ElicitIntent")
        self.assertIn("didn't get that", response["messages"][0]["content"])

    def test_timeout_then_retry_use_a_shared_three_attempt_budget(self):
        attributes = {}
        for transcript, action in (("", "ElicitIntent"), ("unknown", "ElicitIntent"), ("", "Close")):
            response = handler.lambda_handler(invocation(transcript=transcript, attributes=attributes), None)
            self.assertEqual(response["sessionState"]["dialogAction"]["type"], action)
            attributes = response["sessionState"]["sessionAttributes"]

    def test_reprompt_substitutes_phone_placeholders(self):
        attributes = handler.get_session_attributes({})
        attributes.update({
            "menu_prompt": "Confirm $.CustomerEndpoint.Address or $.Attributes.CustomerPhone",
            "CustomerEndpointAddress": "+15550001111", "CustomerPhone": "+15550002222",
        })
        response = handler.lambda_handler(invocation(attributes=attributes), None)
        message = response["messages"][0]["content"]
        self.assertIn("+15550001111", message)
        self.assertIn("+15550002222", message)
        self.assertNotIn("$.", message)

    def test_zip_contains_the_current_source_at_root(self):
        with ZipFile(SOURCE.with_suffix(".zip")) as package:
            self.assertEqual(package.namelist(), ["lambda_function.py"])
            self.assertEqual(package.read("lambda_function.py"), SOURCE.read_bytes())


if __name__ == "__main__":
    unittest.main()
