import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit


SOURCE = Path(__file__).parents[1] / "src" / "lambda_function.py"
spec = importlib.util.spec_from_file_location("interaction_handler", SOURCE)
handler = importlib.util.module_from_spec(spec)
with patch.dict(os.environ, {"SN_INSTANCE": "abbvienowdev", "SN_CTI_RULE": "cti_gsd"}):
    spec.loader.exec_module(handler)

CONTACT_ID = "11111111-2222-3333-4444-555555555555"


class HandlerTests(unittest.TestCase):
    def test_direct_request_preserves_and_encodes_summary(self):
        summary = "Space + & accents: caf\u00e9"
        response = handler.lambda_handler(
            {"upi": "TEST-123", "contact_id": CONTACT_ID, "description": summary},
            None,
        )
        self.assertEqual(response["Status"], "success")
        url = response["ScreenPopURL"]
        self.assertEqual(urlsplit(url).netloc, "abbvienowdev.service-now.com")
        query = parse_qs(urlsplit(url).query)
        self.assertEqual(query["sysparm_caller_id"], ["TEST-123"])
        self.assertEqual(query["sysparm_correlation_id"], [CONTACT_ID])
        self.assertEqual(query["sysparm_cti_rule"], ["cti_gsd"])
        self.assertEqual(query["sysparm_u_description"], [summary])
        self.assertIn("%20", url)
        self.assertIn("%2B", url)
        self.assertIn("%26", url)

    def test_gateway_parameters_are_case_insensitive(self):
        response = handler.lambda_handler(
            {"parameters": {"Upi": " TEST-123 ", "ContactId": CONTACT_ID}}, None
        )
        self.assertEqual(response["UPI"], "TEST-123")
        self.assertEqual(response["CorrelationId"], CONTACT_ID)
        self.assertNotIn("sysparm_u_description", response["ScreenPopURL"])

    def test_contact_flow_falls_back_to_contact_attributes(self):
        response = handler.lambda_handler({"Details": {
            "Parameters": {},
            "ContactData": {
                "ContactId": CONTACT_ID,
                "Attributes": {"UPI": "TEST-123", "CallSummary": "Attribute summary"},
            },
        }}, None)
        query = parse_qs(urlsplit(response["ScreenPopURL"]).query)
        self.assertEqual(response["CorrelationId"], CONTACT_ID)
        self.assertEqual(response["UPI"], "TEST-123")
        self.assertEqual(query["sysparm_u_description"], ["Attribute summary"])

    def test_flow_parameters_override_attribute_fallback(self):
        response = handler.lambda_handler({"Details": {
            "Parameters": {"upi": "PARAM-123", "description": "Explicit summary"},
            "ContactData": {
                "ContactId": CONTACT_ID,
                "Attributes": {"UPI": "ATTR-123", "CallSummary": "Attribute summary"},
            },
        }}, None)
        query = parse_qs(urlsplit(response["ScreenPopURL"]).query)
        self.assertEqual(response["UPI"], "PARAM-123")
        self.assertEqual(query["sysparm_u_description"], ["Explicit summary"])

    def test_missing_and_invalid_identifiers(self):
        cases = [
            ({}, "MissingContactId"),
            ({"ContactId": CONTACT_ID}, "MissingUPI"),
            ({"ContactId": CONTACT_ID, "upi": "bad&value"}, "InvalidUPI"),
            ({"ContactId": "invalid", "upi": "TEST-123"}, "InvalidContactId"),
            ({"ContactId": CONTACT_ID, "upi": "A" * 33}, "InvalidUPI"),
            ({"ContactId": "z" + CONTACT_ID[1:], "upi": "TEST-123"}, "InvalidContactId"),
        ]
        for event, error in cases:
            with self.subTest(error=error):
                response = handler.lambda_handler(event, None)
                self.assertEqual(response["Status"], "Failure")
                self.assertEqual(response["Error"], error)
                self.assertNotIn("ScreenPopURL", response)

    def test_complete_url_character_limit_preserves_identifiers(self):
        with self.assertLogs(level="WARNING"):
            response = handler.lambda_handler({
                "UPI": "TEST-123", "ContactId": CONTACT_ID,
                "CallSummary": "a" * 3100,
            }, None)
        url = response["ScreenPopURL"]
        self.assertEqual(len(url), 3000)
        self.assertLessEqual(len(url.encode("utf-8")), 8192)
        query = parse_qs(urlsplit(url).query)
        self.assertEqual(query["sysparm_caller_id"], ["TEST-123"])
        self.assertEqual(query["sysparm_correlation_id"], [CONTACT_ID])
        self.assertLess(len(query["sysparm_u_description"][0]), 3000)

    def test_encoded_url_keeps_complete_multibyte_characters(self):
        for character in ["\u6c49", "\U0001f600"]:
            with self.subTest(character=character), self.assertLogs(level="WARNING"):
                url = handler.build_screen_pop_url("TEST-123", CONTACT_ID, character * 3000)
            self.assertLessEqual(len(url), 3000)
            self.assertLessEqual(len(url.encode("utf-8")), 8192)
            query = parse_qs(urlsplit(url).query, errors="strict")
            summary = query["sysparm_u_description"][0]
            self.assertEqual(summary, character * len(summary))
            self.assertFalse(handler.url_within_limits(
                handler.compose_url("TEST-123", CONTACT_ID, summary + character)
            ))

    def test_url_limit_accounts_for_percent_encoding_of_shorter_summaries(self):
        summary = " &+/%\u6c49\U0001f600" * 200
        self.assertLess(len(summary), 3000)
        with self.assertLogs(level="WARNING"):
            url = handler.build_screen_pop_url("TEST-123", CONTACT_ID, summary)
        self.assertLessEqual(len(url), 3000)
        self.assertLessEqual(len(url.encode("utf-8")), 8192)
        retained = parse_qs(urlsplit(url).query, errors="strict")["sysparm_u_description"][0]
        self.assertTrue(summary.startswith(retained))
        self.assertLess(len(retained), len(summary))

    def test_stage_environment_override_selects_stage_hostname(self):
        with patch.object(handler, "SN_INSTANCE", "abbvienowstage"):
            response = handler.lambda_handler({"UPI": "TEST-123", "ContactId": CONTACT_ID}, None)
        self.assertEqual(urlsplit(response["ScreenPopURL"]).netloc, "abbvienowstage.service-now.com")

    def test_oversized_base_url_is_rejected_instead_of_truncating_identifiers(self):
        with patch.object(handler, "SN_INSTANCE", "a" * 4000):
            with self.assertRaisesRegex(ValueError, "within URL limits"):
                handler.build_screen_pop_url("TEST-123", CONTACT_ID, "summary")

    def test_malformed_contact_flow_and_empty_summary(self):
        self.assertEqual(handler.lambda_handler({"Details": None}, None)["Error"], "MissingContactId")
        url = handler.build_screen_pop_url("TEST-123", CONTACT_ID, "")
        self.assertNotIn("sysparm_u_description", parse_qs(urlsplit(url).query))


if __name__ == "__main__":
    unittest.main()
