import csv
import importlib.util
import io
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "v2v_modules/lambda-connect-daily-ctr-consolidation/src/lambda_function.py"
REGIONS = ("NORAM", "EMEA", "JAPAC")
FILENAMES = {"ACD": "btsgsd_abbvieacd.csv", "SURVEY": "btsgsd_abbvieacdsurvey.csv"}


class FakeClientError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.response = {"Error": {"Code": code}}


class CTRConsolidationRollingWindowTests(unittest.TestCase):
    def setUp(self):
        self.objects = {}
        self.uploads = []
        self.s3 = Mock()
        self.s3.head_object.side_effect = self.head_object
        self.s3.get_object.side_effect = self.get_object
        self.s3.upload_file.side_effect = self.upload_file
        sdk = types.ModuleType("boto3")
        sdk.client = Mock(return_value=self.s3)
        botocore = types.ModuleType("botocore")
        config = types.ModuleType("botocore.config")
        config.Config = Mock()
        exceptions = types.ModuleType("botocore.exceptions")
        exceptions.ClientError = FakeClientError
        spec = importlib.util.spec_from_file_location("ctr_consolidation_under_test", SOURCE)
        self.report = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {
            "boto3": sdk, "botocore": botocore,
            "botocore.config": config, "botocore.exceptions": exceptions,
        }), patch.dict(os.environ, {
            "REPORT_BUCKET": "test-reports", "S3_REGION": "us-east-1",
            "ACD_SOURCE_PREFIX": "daily/acd/", "SURVEY_SOURCE_PREFIX": "daily/survey/",
            "OUTPUT_PREFIX": "consolidated/", "EXPECTED_REGIONS": ",".join(REGIONS),
            "BUSINESS_TIMEZONE": "EST", "FAIL_IF_REGION_MISSING": "TRUE",
            "ADD_SOURCE_COLUMNS": "FALSE", "CSV_ENCODING": "utf-8-sig",
            "CSV_DELIMITER": ",", "SSE_KMS_KEY_ID": "", "MAX_SOURCE_BYTES": "1048576",
        }):
            spec.loader.exec_module(self.report)
        self.report.logger = Mock()
        self.event = {"scheduled_time": "2026-11-11T08:00:00Z", "reportType": "ALL"}
        self.add_sources()

        # Redirect Lambda's /tmp to an isolated local test directory.
        real_temporary_directory = tempfile.TemporaryDirectory
        temporary = real_temporary_directory(prefix=".ctr-consolidation-test-", dir=ROOT)
        self.addCleanup(temporary.cleanup)
        redirect = patch.object(self.report.tempfile, "TemporaryDirectory", side_effect=lambda **kwargs:
                                real_temporary_directory(dir=temporary.name, prefix=kwargs["prefix"]))
        redirect.start()
        self.addCleanup(redirect.stop)

    def add_sources(self):
        for kind, filename in FILENAMES.items():
            for region in REGIONS:
                key = f"daily/{kind.lower()}/{region}/{filename}"
                self.objects[key] = {
                    "body": f"id,value\r\n{region},{kind}\r\n".encode("utf-8-sig"),
                    "etag": f'"{kind}-{region}"',
                    "metadata": {
                        "window-start": "2026-11-04", "window-end": "2026-11-10",
                        "window-end-exclusive": "2026-11-11", "lookback-days": "7",
                        "business-timezone": "EST", "row-count": "1",
                    },
                }

    def head_object(self, *, Bucket, Key):
        self.assertEqual(Bucket, "test-reports")
        if Key not in self.objects:
            raise FakeClientError("NoSuchKey")
        source = self.objects[Key]
        return {"Metadata": source["metadata"].copy(), "ETag": source["etag"],
                "ContentLength": len(source["body"])}

    def get_object(self, *, Bucket, Key, IfMatch):
        self.assertEqual(Bucket, "test-reports")
        source = self.objects[Key]
        self.assertEqual(IfMatch, source["etag"])
        return {"Body": io.BytesIO(source["body"])}

    def upload_file(self, *, Filename, Bucket, Key, ExtraArgs):
        self.assertEqual(Bucket, "test-reports")
        self.uploads.append({"key": Key, "extra": ExtraArgs, "body": Path(Filename).read_bytes()})

    def test_all_reports_merge_three_regions_into_two_fixed_outputs(self):
        result = self.report.lambda_handler(self.event, None)
        self.assertEqual(result["windowStart"], "2026-11-04")
        self.assertEqual(result["windowEnd"], "2026-11-10")
        self.assertEqual(result["windowEndExclusive"], "2026-11-11")
        self.assertEqual(result["businessTimezone"], "EST")
        self.assertEqual(self.s3.get_object.call_count, 6)
        self.assertEqual(len(self.uploads), 2)
        for kind, upload, summary in zip(FILENAMES, self.uploads, result["results"]):
            self.assertEqual(upload["key"], f"consolidated/{FILENAMES[kind]}")
            rows = list(csv.DictReader(io.StringIO(upload["body"].decode("utf-8-sig"))))
            self.assertEqual(rows, [{"id": region, "value": kind} for region in REGIONS])
            self.assertEqual(summary["dataRows"], 3)
            self.assertEqual(summary["regionalRowCounts"], dict.fromkeys(REGIONS, 1))
            self.assertNotIn("localPath", summary)
            self.assertEqual(upload["extra"]["Metadata"]["row-count"], "3")
            self.assertEqual(upload["extra"]["Metadata"]["source-file-count"], "3")
            self.assertNotIn("ServerSideEncryption", upload["extra"])

    def test_report_type_limits_sources_and_outputs(self):
        for kind in FILENAMES:
            with self.subTest(kind=kind):
                self.uploads.clear()
                self.s3.head_object.reset_mock()
                self.report.lambda_handler(dict(self.event, reportType=kind), None)
                self.assertEqual([upload["key"] for upload in self.uploads],
                                 [f"consolidated/{FILENAMES[kind]}"])
                for call in self.s3.head_object.call_args_list:
                    self.assertTrue(call.kwargs["Key"].startswith(f"daily/{kind.lower()}/"))

    def test_stale_window_or_incompatible_timezone_prevents_any_upload(self):
        metadata = self.objects[f"daily/survey/EMEA/{FILENAMES['SURVEY']}"]["metadata"]
        for field, bad_value in (("window-start", "2026-11-03"), ("business-timezone", "UTC")):
            with self.subTest(field=field):
                original = metadata[field]
                metadata[field] = bad_value
                with self.assertRaisesRegex(RuntimeError, "stale or incompatible"):
                    self.report.lambda_handler(self.event, None)
                self.assertEqual(self.uploads, [])
                metadata[field] = original

    def test_invalid_second_report_prevents_publishing_either_report(self):
        source = self.objects[f"daily/survey/EMEA/{FILENAMES['SURVEY']}"]
        for body, expected in (
            ("id,other\nEMEA,SURVEY\n", "schema mismatch"),
            ("id,id\nEMEA,SURVEY\n", "Invalid/duplicate CSV headers"),
            ("id,value\nEMEA,SURVEY,extra\n", "Invalid row width"),
            ("id,value\n", "Row-count mismatch"),
        ):
            with self.subTest(expected=expected):
                source["body"] = body.encode("utf-8-sig")
                with self.assertRaisesRegex(RuntimeError, expected):
                    self.report.lambda_handler(self.event, None)
                self.assertEqual(self.uploads, [])

    def test_missing_regions_fail_unless_partial_output_is_enabled(self):
        del self.objects[f"daily/acd/JAPAC/{FILENAMES['ACD']}"]
        event = dict(self.event, reportType="ACD")
        with self.assertRaisesRegex(RuntimeError, "missing regional files"):
            self.report.lambda_handler(event, None)
        self.assertEqual(self.uploads, [])
        self.report.FAIL_IF_REGION_MISSING = False
        result = self.report.lambda_handler(event, None)
        self.assertEqual(result["results"][0]["missingRegions"], ["JAPAC"])
        self.assertEqual(result["results"][0]["dataRows"], 2)
        self.assertEqual(self.uploads[0]["extra"]["Metadata"]["missing-regions"], "JAPAC")

    def test_access_denied_is_not_treated_as_a_missing_source(self):
        self.report.FAIL_IF_REGION_MISSING = False
        self.s3.head_object.side_effect = FakeClientError("AccessDenied")
        with self.assertRaises(FakeClientError):
            self.report.lambda_handler(self.event, None)
        self.assertEqual(self.uploads, [])

    def test_source_changes_during_preparation_prevent_any_upload(self):
        observed = set()

        def changing_head(**kwargs):
            result = self.head_object(**kwargs)
            if kwargs["Key"] in observed:
                result["ETag"] = '"changed"'
            observed.add(kwargs["Key"])
            return result

        self.s3.head_object.side_effect = changing_head
        with self.assertRaisesRegex(RuntimeError, "Source changed during consolidation"):
            self.report.lambda_handler(self.event, None)
        self.assertEqual(self.uploads, [])

    def test_size_limit_and_execution_deadline_stop_before_upload(self):
        self.report.MAX_SOURCE_BYTES = 1
        with self.assertRaisesRegex(RuntimeError, "MAX_SOURCE_BYTES"):
            self.report.lambda_handler(self.event, None)
        self.s3.get_object.assert_not_called()
        context = Mock()
        context.get_remaining_time_in_millis.return_value = 59000
        with self.assertRaisesRegex(RuntimeError, "Insufficient execution time"):
            self.report.lambda_handler(self.event, context)
        self.assertEqual(self.uploads, [])

    def test_scheduled_business_date_and_invalid_overrides(self):
        run, start, end, *_ = self.report.get_rolling_window({
            "scheduled_time": "2026-11-11T03:00:00Z",
        })
        self.assertEqual([str(run), str(start), str(end)],
                         ["2026-11-10", "2026-11-03", "2026-11-09"])
        for event in (
            {"scheduled_time": "2026-11-11T08:00:00"},
            {"as_of_date": "2026-11-11", "reportDate": "2026-11-10"},
            {"as_of_date": "2026-02-30"},
            {"reportType": "INVALID"},
        ):
            with self.subTest(event=event), self.assertRaises(ValueError):
                self.report.lambda_handler(event, None)
        self.assertEqual(self.uploads, [])

    def test_source_tracking_and_explicit_kms_key(self):
        self.report.ADD_SOURCE_COLUMNS = True
        self.report.SSE_KMS_KEY_ID = "test-kms-key"
        self.report.lambda_handler(dict(self.event, reportType="ACD"), None)
        upload = self.uploads[0]
        self.assertEqual(upload["extra"]["ServerSideEncryption"], "aws:kms")
        self.assertEqual(upload["extra"]["SSEKMSKeyId"], "test-kms-key")
        rows = list(csv.DictReader(io.StringIO(upload["body"].decode("utf-8-sig"))))
        self.assertEqual([row["SourceRegion"] for row in rows], list(REGIONS))
        self.assertEqual(rows[0]["SourceFile"], f"daily/acd/NORAM/{FILENAMES['ACD']}")

    def test_output_cannot_overwrite_a_regional_source(self):
        self.report.OUTPUT_PREFIX = "daily/acd/NORAM"
        with self.assertRaisesRegex(ValueError, "must not overwrite a regional source"):
            self.report.lambda_handler(dict(self.event, reportType="ACD"), None)
        self.assertEqual(self.uploads, [])


if __name__ == "__main__":
    unittest.main()
