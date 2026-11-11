import importlib.util
import os
from pathlib import Path
import sys
import types
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import Mock, patch


SOURCE = (
    Path(__file__).resolve().parents[2]
    / "v2v_modules/lambda-ctr-survey/src/lambda_function_ctr_.py"
)


class CTRSurveyRollingWindowTests(unittest.TestCase):
    def setUp(self):
        sdk = types.ModuleType("boto3")
        sdk.client = Mock(side_effect=lambda *args, **kwargs: Mock())
        spec = importlib.util.spec_from_file_location("ctr_survey_under_test", SOURCE)
        self.survey = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {"boto3": sdk}), patch.dict(os.environ, {
            "CONNECT_INSTANCE_ID": "test-instance",
            "S3_BUCKET": "test-reports",
            "S3_REGION": "us-east-1",
            "S3_PREFIX": "daily/survey/NORAM",
            "BUSINESS_TIMEZONE": "EST",
        }):
            spec.loader.exec_module(self.survey)
        self.survey.logger = Mock()
        self.survey.search_contacts = Mock(return_value=[])
        self.survey.describe_contact = Mock()
        self.survey.build_survey_row = Mock(return_value={"Survey Start Time": "valid"})

    def test_window_contains_seven_complete_business_days(self):
        run, start, end, start_local, end_local = self.survey.get_rolling_window({
            "as_of_date": "2026-11-11",
        })
        self.assertEqual(str(run), "2026-11-11")
        self.assertEqual(str(start), "2026-11-04")
        self.assertEqual(str(end), "2026-11-10")
        self.assertEqual(start_local.isoformat(), "2026-11-04T00:00:00-05:00")
        self.assertEqual(end_local.isoformat(), "2026-11-11T00:00:00-05:00")

    def test_scheduled_timestamp_uses_business_date_instead_of_utc_date(self):
        run, start, end, *_ = self.survey.get_rolling_window({
            "scheduled_time": "2026-11-11T03:00:00Z",
        })
        self.assertEqual(str(run), "2026-11-10")
        self.assertEqual(str(start), "2026-11-03")
        self.assertEqual(str(end), "2026-11-09")

    def test_legacy_report_date_remains_the_inclusive_end_date(self):
        for key in ("reportDate", "report_date"):
            with self.subTest(key=key):
                run, start, end, *_ = self.survey.get_rolling_window({key: "2026-11-10"})
                self.assertEqual(str(run), "2026-11-11")
                self.assertEqual(str(start), "2026-11-04")
                self.assertEqual(str(end), "2026-11-10")

    def test_rejects_ambiguous_or_invalid_date_overrides(self):
        for event in (
            {"as_of_date": "2026-11-11", "scheduled_time": "2026-11-11T08:00:00Z"},
            {"reportDate": "2026-11-10", "report_date": "2026-11-10"},
            {"scheduled_time": "2026-11-11T08:00:00"},
            {"as_of_date": "2026-02-30"},
        ):
            with self.subTest(event=event), self.assertRaises(ValueError):
                self.survey.get_rolling_window(event)

    def test_calendar_window_preserves_midnights_across_daylight_saving_change(self):
        self.survey.BUSINESS_TIMEZONE = "America/Chicago"
        _, _, _, start, end = self.survey.get_rolling_window({"as_of_date": "2026-11-04"})
        self.assertEqual(start.isoformat(), "2026-10-28T00:00:00-05:00")
        self.assertEqual(end.isoformat(), "2026-11-04T00:00:00-06:00")
        self.assertEqual(
            end.astimezone(timezone.utc) - start.astimezone(timezone.utc),
            timedelta(hours=169),
        )

    def test_searches_each_day_deduplicates_and_excludes_outside_boundaries(self):
        start = datetime(2026, 11, 4, 5, tzinfo=timezone.utc)
        end = datetime(2026, 11, 11, 5, tzinfo=timezone.utc)
        contacts = {
            key: {"Id": key, "InitiationTimestamp": stamp}
            for key, stamp in (
                ("start", start), ("inside", start + timedelta(hours=1)),
                ("before", start - timedelta(seconds=1)), ("end", end),
            )
        }
        # Repeat every summary on every daily page to exercise deduplication.
        self.survey.search_contacts.return_value = [{"Id": key} for key in contacts]
        self.survey.describe_contact.side_effect = contacts.__getitem__

        result = self.survey.lambda_handler({"as_of_date": "2026-11-11"}, None)

        self.assertEqual(self.survey.search_contacts.call_count, 7)
        for index, call in enumerate(self.survey.search_contacts.call_args_list):
            self.assertEqual(call.args, (
                start + timedelta(days=index), start + timedelta(days=index + 1),
            ))
        self.assertEqual(self.survey.describe_contact.call_count, 4)
        self.assertEqual(self.survey.build_survey_row.call_count, 2)
        self.assertEqual(result["sourceContacts"], 4)
        self.assertEqual(result["describedContacts"], 2)
        self.assertEqual(result["lookbackDays"], 7)
        self.survey.s3.put_object.assert_called_once()
        upload = self.survey.s3.put_object.call_args.kwargs
        self.assertEqual(upload["Bucket"], "test-reports")
        self.assertEqual(upload["Key"], "daily/survey/NORAM/btsgsd_abbvieacdsurvey.csv")
        self.assertEqual(upload["Metadata"]["window-start"], "2026-11-04")
        self.assertEqual(upload["Metadata"]["window-end"], "2026-11-10")
        self.assertEqual(upload["Metadata"]["window-end-exclusive"], "2026-11-11")

    def test_contact_and_row_failures_never_replace_the_existing_snapshot(self):
        self.survey.search_contacts.return_value = [{"Id": "broken"}]
        for failure in ("describe", "timestamp", "row"):
            with self.subTest(failure=failure):
                self.survey.s3.reset_mock()
                self.survey.describe_contact.side_effect = None
                self.survey.describe_contact.return_value = {
                    "Id": "broken", "InitiationTimestamp": "2026-11-05T12:00:00Z",
                }
                self.survey.build_survey_row.side_effect = None
                if failure == "describe":
                    self.survey.describe_contact.side_effect = RuntimeError("API failure")
                elif failure == "timestamp":
                    self.survey.describe_contact.return_value.pop("InitiationTimestamp")
                else:
                    self.survey.build_survey_row.side_effect = ValueError("Invalid row")
                with self.assertRaisesRegex(RuntimeError, "Survey export incomplete"):
                    self.survey.lambda_handler({"as_of_date": "2026-11-11"}, None)
                self.survey.s3.put_object.assert_not_called()


if __name__ == "__main__":
    unittest.main()
