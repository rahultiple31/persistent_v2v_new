import csv
import importlib.util
import io
import os
from pathlib import Path
import sys
import types
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import Mock, patch


SOURCE = (
    Path(__file__).resolve().parents[2]
    / "v2v_modules/lambda-connect-daily-ctr-export/src/lambda_function_ctr_export.py"
)


class CTRExportRollingWindowTests(unittest.TestCase):
    def setUp(self):
        sdk = types.ModuleType("boto3")
        sdk.client = Mock(side_effect=lambda *args, **kwargs: Mock())
        spec = importlib.util.spec_from_file_location("ctr_export_under_test", SOURCE)
        self.export = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {"boto3": sdk}), patch.dict(os.environ, {
            "CONNECT_INSTANCE_ID": "test-instance",
            "S3_BUCKET": "test-reports",
            "S3_REGION": "us-east-1",
            "S3_PREFIX": "daily/acd/NORAM",
            "BUSINESS_TIMEZONE": "EST",
        }):
            spec.loader.exec_module(self.export)
        self.export.logger = Mock()
        self.export.search_contacts = Mock(return_value=[])
        self.export.describe_contact = Mock()
        self.export.build_csv_row = Mock(side_effect=lambda *args: {})

    def test_window_uses_scheduled_business_date_and_legacy_end_date(self):
        for event in (
            {"scheduled_time": "2026-11-11T03:00:00Z"},
            {"as_of_date": "2026-11-10"},
            {"reportDate": "2026-11-09"},
            {"report_date": "2026-11-09"},
        ):
            with self.subTest(event=event):
                run, start, end, start_local, end_local = self.export.get_rolling_window(event)
                self.assertEqual(str(run), "2026-11-10")
                self.assertEqual(str(start), "2026-11-03")
                self.assertEqual(str(end), "2026-11-09")
                self.assertEqual(start_local.isoformat(), "2026-11-03T00:00:00-05:00")
                self.assertEqual(end_local.isoformat(), "2026-11-10T00:00:00-05:00")

    def test_rejects_ambiguous_or_invalid_date_overrides(self):
        for event in (
            {"as_of_date": "2026-11-11", "scheduled_time": "2026-11-11T08:00:00Z"},
            {"reportDate": "2026-11-10", "report_date": "2026-11-10"},
            {"scheduled_time": "2026-11-11T08:00:00"},
            {"as_of_date": "2026-02-30"},
        ):
            with self.subTest(event=event), self.assertRaises(ValueError):
                self.export.get_rolling_window(event)

    def test_daily_searches_deduplicate_and_preserve_segments_in_one_root_row(self):
        start = datetime(2026, 11, 4, 5, tzinfo=timezone.utc)
        end = datetime(2026, 11, 11, 5, tzinfo=timezone.utc)
        contacts = {
            key: {"Id": key, "InitialContactId": "root", "InitiationTimestamp": stamp}
            for key, stamp in (
                ("start", start), ("inside", start + timedelta(hours=1)),
                ("before", start - timedelta(seconds=1)), ("end", end),
            )
        }
        self.export.search_contacts.return_value = [{"Id": key} for key in contacts]
        self.export.describe_contact.side_effect = contacts.__getitem__

        result = self.export.lambda_handler({"as_of_date": "2026-11-11"}, None)

        self.assertEqual(self.export.search_contacts.call_count, 7)
        for index, call in enumerate(self.export.search_contacts.call_args_list):
            self.assertEqual(call.args, (
                start + timedelta(days=index), start + timedelta(days=index + 1),
            ))
        self.assertEqual(self.export.describe_contact.call_count, 4)
        self.export.build_csv_row.assert_called_once()
        segments = self.export.build_csv_row.call_args.args[0]
        self.assertEqual([item["Id"] for item in segments], ["start", "inside"])
        self.assertEqual(result["sourceContacts"], 4)
        self.assertEqual(result["describedContacts"], 2)
        self.assertEqual(result["rootInteractions"], 1)
        self.assertEqual(result["csvRows"], 1)
        self.export.s3.put_object.assert_called_once()
        upload = self.export.s3.put_object.call_args.kwargs
        self.assertEqual(upload["Bucket"], "test-reports")
        self.assertEqual(upload["Key"], "daily/acd/NORAM/btsgsd_abbvieacd.csv")
        self.assertEqual(upload["Metadata"]["window-start"], "2026-11-04")
        self.assertEqual(upload["Metadata"]["window-end"], "2026-11-10")
        self.assertEqual(upload["Metadata"]["window-end-exclusive"], "2026-11-11")
        rows = list(csv.DictReader(io.StringIO(upload["Body"].decode("utf-8-sig"))))
        self.assertEqual([row["Root_Interaction_ID"] for row in rows], ["root"])

    def test_repeated_runs_replace_the_same_key_and_support_an_empty_prefix(self):
        for prefix, expected_key in (
            ("daily/acd/NORAM", "daily/acd/NORAM/btsgsd_abbvieacd.csv"),
            ("", "btsgsd_abbvieacd.csv"),
        ):
            with self.subTest(prefix=prefix):
                self.export.S3_PREFIX = prefix
                self.export.s3.reset_mock()
                for run_date in ("2026-11-11", "2026-11-12"):
                    result = self.export.lambda_handler({"as_of_date": run_date}, None)
                    self.assertEqual(result["key"], expected_key)
                    self.assertEqual(result["lookbackDays"], 7)
                self.assertEqual(self.export.s3.put_object.call_count, 2)
                self.assertEqual(
                    [call.kwargs["Key"] for call in self.export.s3.put_object.call_args_list],
                    [expected_key, expected_key],
                )

    def test_calendar_day_searches_account_for_daylight_saving_change(self):
        self.export.BUSINESS_TIMEZONE = "America/Chicago"
        self.export.lambda_handler({"as_of_date": "2026-11-04"}, None)
        calls = self.export.search_contacts.call_args_list
        self.assertEqual(len(calls), 7)
        self.assertEqual(calls[0].args[0].isoformat(), "2026-10-28T05:00:00+00:00")
        self.assertEqual(calls[-1].args[1].isoformat(), "2026-11-04T06:00:00+00:00")
        durations = [call.args[1] - call.args[0] for call in calls]
        self.assertEqual(durations.count(timedelta(hours=25)), 1)
        self.assertEqual(sum(durations, timedelta()), timedelta(hours=169))

    def test_contact_and_row_failures_never_replace_the_existing_snapshot(self):
        self.export.search_contacts.return_value = [{"Id": "broken"}]
        for failure in ("describe", "timestamp", "row"):
            with self.subTest(failure=failure):
                self.export.s3.reset_mock()
                self.export.describe_contact.side_effect = None
                self.export.describe_contact.return_value = {
                    "Id": "broken", "InitiationTimestamp": "2026-11-05T12:00:00Z",
                }
                self.export.build_csv_row.side_effect = lambda *args: {}
                if failure == "describe":
                    self.export.describe_contact.side_effect = RuntimeError("API failure")
                elif failure == "timestamp":
                    self.export.describe_contact.return_value.pop("InitiationTimestamp")
                else:
                    self.export.build_csv_row.side_effect = ValueError("Invalid row")
                with self.assertRaisesRegex(RuntimeError, "Export incomplete"):
                    self.export.lambda_handler({"as_of_date": "2026-11-11"}, None)
                self.export.s3.put_object.assert_not_called()


if __name__ == "__main__":
    unittest.main()
