import importlib.util
import os
from pathlib import Path
import unittest
from datetime import datetime
from unittest.mock import Mock, patch
from zipfile import ZipFile


SOURCE = Path(__file__).resolve().parents[3] / "environments/v2v/metadata/conversionOfQueueMetrics-dev_lambda/lambda_function.py"
spec = importlib.util.spec_from_file_location("queue_metrics_handler", SOURCE)
handler = importlib.util.module_from_spec(spec)
with patch("boto3.resource"), patch.dict(os.environ, {"TableName": "queueInfo", "TTL_SECONDS": "86400"}):
    spec.loader.exec_module(handler)


def invocation(kind, **parameters):
    return {"Details": {
        "ContactData": {"ContactId": "contact-123"},
        "Parameters": {"invocationType": kind, **parameters},
    }}


class HandlerTests(unittest.TestCase):
    def test_zip_contains_current_source_at_root(self):
        with ZipFile(SOURCE.with_suffix(".zip")) as package:
            self.assertEqual(package.namelist(), ["lambda_function.py"])
            self.assertEqual(package.read("lambda_function.py"), SOURCE.read_bytes())

    def setUp(self):
        self.table = Mock()
        table_patch = patch.object(handler, "table", self.table)
        table_patch.start()
        self.addCleanup(table_patch.stop)
        clock_patch = patch.object(handler, "datetime", wraps=datetime)
        self.clock = clock_patch.start()
        self.clock.now.return_value = datetime(2026, 10, 19, 12, 1, 0)
        self.addCleanup(clock_patch.stop)

    def test_put_queue_saves_timestamp_and_ttl(self):
        self.table.update_item.return_value = {"Attributes": {
            "callId": "contact-123", "times": "10/19/2026 12:01:00",
        }}
        with patch.object(handler.time, "time", return_value=1000):
            response = handler.lambda_handler(invocation("putQueue"), None)
        self.assertEqual(response, {"callId": "contact-123", "times": "10/19/2026 12:01:00"})
        self.table.update_item.assert_called_once_with(
            Key={"callId": "contact-123"},
            UpdateExpression="SET times = :val1, #ttl = :ttl",
            ExpressionAttributeNames={"#ttl": "ttl"},
            ExpressionAttributeValues={":val1": "10/19/2026 12:01:00", ":ttl": 87400},
            ReturnValues="ALL_NEW",
        )

    def test_wait_estimate_subtracts_elapsed_time_and_returns_strings(self):
        self.table.get_item.return_value = {"Item": {"times": "10/19/2026 12:00:00"}}
        response = handler.lambda_handler(invocation("getEWT", queue_time="321", positionInQueue="3"), None)
        self.assertEqual(response, {
            "callId": "contact-123", "ewt": "4 minutes 21 seconds",
            "ewtSeconds": "261", "positionInQueue": "3",
        })
        self.table.get_item.assert_called_once_with(Key={"callId": "contact-123"})
        self.assertEqual(self.table.update_item.call_args.kwargs["ExpressionAttributeValues"], {":val1": 261})

    def test_elapsed_time_never_produces_negative_estimate(self):
        self.table.get_item.return_value = {"Item": {"times": "10/19/2026 12:00:00"}}
        response = handler.lambda_handler(invocation("getEWT", queue_time="30"), None)
        self.assertEqual(response["ewtSeconds"], "0")
        self.assertEqual(response["ewt"], "0 seconds")

    def test_missing_queue_record_returns_zero_without_updating(self):
        for result in ({}, {"Item": {"callId": "contact-123"}}):
            with self.subTest(result=result):
                self.table.get_item.return_value = result
                response = handler.lambda_handler(invocation("getEWT"), None)
                self.assertEqual(response["ewtSeconds"], "0")
                self.assertEqual(response["positionInQueue"], "1")
        self.table.update_item.assert_not_called()

    def test_missing_contact_and_unsupported_invocations_do_not_write(self):
        self.assertEqual(handler.lambda_handler({}, None), {"error": "ContactId missing"})
        self.assertEqual(handler.lambda_handler(invocation("other"), None), {
            "error": "Unsupported invocationType: other",
        })
        self.table.get_item.assert_not_called()
        self.table.update_item.assert_not_called()

    def test_numeric_fallbacks_and_wait_text(self):
        for value, expected in ((None, 7), (" ", 7), ("bad", 7), ("12.9", 12), (0, 0)):
            with self.subTest(value=value):
                self.assertEqual(handler.to_int(value, 7), expected)
        for seconds, expected in ((-1, "0 seconds"), (34, "34 seconds"),
                                  (60, "1 minute"), (61, "1 minute 1 second")):
            with self.subTest(seconds=seconds):
                self.assertEqual(handler.format_ewt(seconds), expected)


if __name__ == "__main__":
    unittest.main()
