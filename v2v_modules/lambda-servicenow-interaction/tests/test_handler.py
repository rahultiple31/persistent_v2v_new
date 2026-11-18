import importlib
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit
from zipfile import ZipFile


SOURCE = Path(__file__).parents[1] / "src" / "lambda_function.py"
spec = importlib.util.spec_from_file_location("interaction_handler", SOURCE)
handler = importlib.util.module_from_spec(spec)
with patch.dict(os.environ, {
    "SN_INSTANCE": "abbvienowdev", "SN_CTI_RULE": "cti_gsd",
    "SN_ENRICH_CALLER": "true", "SN_PHONE_SYS_ID_ATTRS": "",
    "SN_UPI_SYS_ID_ATTRS": "", "SN_USER_ID_ATTRS": "", "SN_PHONE_ATTRS": "",
}):
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

    def test_phone_lookup_has_priority_over_upi_lookup(self):
        response = handler.lambda_handler({
            "UPI": "TEST-123", "ContactId": CONTACT_ID,
            "CallerSysId": "A" * 32, "UPISysId": "b" * 32,
            "UserId": "TIPLERX", "CallerPhone": "+1 (555) 123-4567",
        }, None)
        query = parse_qs(urlsplit(response["ScreenPopURL"]).query)
        self.assertEqual(query["sysparm_caller_sys_id"], ["a" * 32])
        self.assertEqual(query["sysparm_caller_user_id"], ["TIPLERX"])
        self.assertEqual(query["sysparm_caller_phone"], ["+15551234567"])

    def test_invalid_phone_lookup_falls_back_to_upi_lookup(self):
        with self.assertLogs(level="WARNING"):
            response = handler.lambda_handler({
                "parameters": {
                    "UPI": "TEST-123", "ContactId": CONTACT_ID,
                    "CallerSysId": "invalid", "UPISysId": "B" * 32,
                    "UserId": "bad&value", "CallerPhone": "not a number",
                },
            }, None)
        query = parse_qs(urlsplit(response["ScreenPopURL"]).query)
        self.assertEqual(query["sysparm_caller_sys_id"], ["b" * 32])
        self.assertNotIn("sysparm_caller_user_id", query)
        self.assertNotIn("sysparm_caller_phone", query)

    def test_flow_identity_parameters_override_attributes_and_use_ani(self):
        response = handler.lambda_handler({"Details": {
            "Parameters": {"CallerSysId": "A" * 32, "UserId": "EXPLICIT"},
            "ContactData": {
                "ContactId": CONTACT_ID,
                "Attributes": {
                    "UPI": "TEST-123", "CallerSysId": "b" * 32,
                    "UserId": "ATTRIBUTE",
                },
                "CustomerEndpoint": {"Address": "+15551234567"},
            },
        }}, None)
        query = parse_qs(urlsplit(response["ScreenPopURL"]).query)
        self.assertEqual(query["sysparm_caller_sys_id"], ["a" * 32])
        self.assertEqual(query["sysparm_caller_user_id"], ["EXPLICIT"])
        self.assertEqual(query["sysparm_caller_phone"], ["+15551234567"])

    def test_flow_identity_falls_back_to_attributes(self):
        response = handler.lambda_handler({"Details": {
            "Parameters": {},
            "ContactData": {
                "ContactId": CONTACT_ID,
                "Attributes": {
                    "UPI": "TEST-123", "UPISysId": "B" * 32,
                    "UserId": "ATTRIBUTE", "CallerPhone": "555-1234",
                },
                "CustomerEndpoint": {"Address": "+15551234567"},
            },
        }}, None)
        query = parse_qs(urlsplit(response["ScreenPopURL"]).query)
        self.assertEqual(query["sysparm_caller_sys_id"], ["b" * 32])
        self.assertEqual(query["sysparm_caller_user_id"], ["ATTRIBUTE"])
        self.assertEqual(query["sysparm_caller_phone"], ["5551234"])

    def test_disabled_enrichment_preserves_legacy_url(self):
        with patch.object(handler, "SN_ENRICH_CALLER", False):
            response = handler.lambda_handler({
                "UPI": "TEST-123", "ContactId": CONTACT_ID,
                "CallerSysId": "a" * 32, "UserId": "TIPLERX",
                "CallerPhone": "+15551234567",
            }, None)
        self.assertEqual(
            response["ScreenPopURL"],
            handler.compose_url("TEST-123", CONTACT_ID),
        )

    def test_truncated_summary_retains_identity(self):
        with self.assertLogs(level="WARNING"):
            response = handler.lambda_handler({
                "UPI": "TEST-123", "ContactId": CONTACT_ID,
                "CallerSysId": "a" * 32, "UserId": "TIPLERX",
                "CallerPhone": "+15551234567", "CallSummary": "\U0001f600" * 3000,
            }, None)
        url = response["ScreenPopURL"]
        self.assertTrue(handler.url_within_limits(url))
        query = parse_qs(urlsplit(url).query, errors="strict")
        self.assertEqual(query["sysparm_caller_sys_id"], ["a" * 32])
        self.assertEqual(query["sysparm_caller_user_id"], ["TIPLERX"])
        self.assertEqual(query["sysparm_caller_phone"], ["+15551234567"])
        summary = query["sysparm_u_description"][0]
        self.assertEqual(summary, "\U0001f600" * len(summary))

    def test_attribute_key_environment_override(self):
        with patch.dict(os.environ, {"SN_UPI_SYS_ID_ATTRS": " CustomSysId, OtherSysId "}):
            keys = handler.keys_from_env("SN_UPI_SYS_ID_ATTRS", ())
        self.assertEqual(keys, ("CustomSysId", "OtherSysId"))
        with patch.object(handler, "UPI_SYS_ID_KEYS", keys):
            response = handler.lambda_handler({
                "UPI": "TEST-123", "ContactId": CONTACT_ID,
                "customsysid": "B" * 32,
            }, None)
        query = parse_qs(urlsplit(response["ScreenPopURL"]).query)
        self.assertEqual(query["sysparm_caller_sys_id"], ["b" * 32])


class WarmupWrapperTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        archive = Path(temporary.name) / "interaction.zip"
        # Import both real Python files from the ZIP root, matching source_dir.
        with ZipFile(archive, "w") as package:
            for name in ("lambda_function.py", "warmup_wrapper.py"):
                package.write(SOURCE.parent / name, name)
        for temporary_patch in (
            patch.dict(sys.modules),
            patch.dict(os.environ, {
                "ORIGINAL_HANDLER": "lambda_function.lambda_handler",
                "SN_INSTANCE": "abbvienowdev",
                "SN_CTI_RULE": "cti_gsd",
            }),
            patch.object(sys, "path", [str(archive), *sys.path]),
        ):
            temporary_patch.start()
            self.addCleanup(temporary_patch.stop)
        sys.modules.pop("lambda_function", None)
        sys.modules.pop("warmup_wrapper", None)
        self.wrapper = importlib.import_module("warmup_wrapper")
        self.business = sys.modules["lambda_function"]

    def test_warmup_skips_screen_pop_generation(self):
        with patch.object(self.business, "build_screen_pop_url") as build:
            self.assertEqual(self.wrapper.handler({"warmup": True}, None), {
                "Status": "Success", "Message": "warm",
            })
            build.assert_not_called()

    def test_other_events_delegate_unchanged(self):
        response, context = object(), object()
        with patch.object(self.wrapper, "_original_handler", return_value=response) as original:
            for event in (None, [], {}, {"warmup": False}, {"warmup": "true"}, {"warmup": 1}):
                with self.subTest(event=event):
                    original.reset_mock()
                    self.assertIs(self.wrapper.handler(event, context), response)
                    original.assert_called_once_with(event, context)

    def test_zip_entry_point_generates_contact_flow_screen_pop(self):
        self.assertIs(self.wrapper._original_handler, self.business.lambda_handler)
        response = self.wrapper.handler({"Details": {
            "Parameters": {},
            "ContactData": {
                "ContactId": CONTACT_ID,
                "Attributes": {"UPI": "TEST-123", "CallSummary": "Caller needs IT & account assistance."},
            },
        }}, None)
        self.assertEqual(response["Status"], "success")
        url = urlsplit(response["ScreenPopURL"])
        self.assertEqual(url.netloc, "abbvienowdev.service-now.com")
        self.assertEqual(parse_qs(url.query), {
            "sysparm_cti_rule": ["cti_gsd"],
            "sysparm_caller_id": ["TEST-123"],
            "sysparm_correlation_id": [CONTACT_ID],
            "sysparm_u_description": ["Caller needs IT & account assistance."],
        })

    def test_url_errors_return_structured_failure(self):
        with patch.object(self.business, "build_screen_pop_url", side_effect=ValueError("test URL failure")):
            response = self.wrapper.handler({"UPI": "TEST-123", "ContactId": CONTACT_ID}, None)
        self.assertEqual(response["Status"], "Failure")
        self.assertEqual(response["Error"], "UrlTooLong")
        self.assertNotIn("ScreenPopURL", response)


if __name__ == "__main__":
    unittest.main()
