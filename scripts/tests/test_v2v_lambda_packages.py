import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "v2v_lambda_packages", ROOT / "scripts/v2v-lambda-packages.py"
)
PACKAGES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGES)


class V2VLambdaPackagesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.plan = self.root / "plan-agent"
        self.artifact = self.root / "artifact"
        self.apply = self.root / "apply-agent"

    def sources(self):
        for directory in PACKAGES.CONNECT_DIRECTORIES:
            source = self.plan / "metadata" / directory / "lambda_function.py"
            source.parent.mkdir(parents=True)
            source.write_text("def handler(event, context):\n    return event\n")

    def hashes(self, directory):
        return {
            str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in (directory / "metadata").rglob("*.zip")
        }

    def test_builds_handler_at_archive_root_with_stable_metadata(self):
        self.sources()
        PACKAGES.build("connect", self.plan)
        hashes = self.hashes(self.plan)
        self.assertEqual(len(hashes), 4)
        for source in (self.plan / "metadata").rglob("*.py"):
            with ZipFile(source.with_suffix(".zip")) as package:
                self.assertEqual(package.namelist(), ["lambda_function.py"])
                self.assertEqual(package.read("lambda_function.py"), source.read_bytes())
            os.utime(source, (1700000000, 1700000000))
        PACKAGES.build("connect", self.plan)
        self.assertEqual(self.hashes(self.plan), hashes)

    def test_missing_source_fails_before_terraform(self):
        with self.assertRaisesRegex(FileNotFoundError, "Missing Lambda source"):
            PACKAGES.build("connect", self.plan)

    def test_other_groups_do_not_require_connect_sources(self):
        PACKAGES.build("btsgsd-v2v-us-snow", self.plan)
        self.assertFalse(self.plan.exists())

    def test_transfer_restores_every_package_on_separate_agent(self):
        self.sources()
        PACKAGES.build("connect", self.plan)
        for name in ("snow/lambda.zip", "servicenow/package.zip", "handoff/package.zip",
                     "lambda.zip", "ctr-survey.zip", "ctr-raw.zip", "ctr-export.zip"):
            path = self.plan / "metadata" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            with ZipFile(path, "w") as package:
                package.writestr("lambda_function.py", name)
        (self.plan / "terraform.tfvars").write_text("must not transfer")
        PACKAGES.transfer(self.plan, self.artifact)
        PACKAGES.transfer(self.artifact, self.apply)
        self.assertEqual(len(self.hashes(self.apply)), 11)
        self.assertEqual(self.hashes(self.plan), self.hashes(self.apply))
        self.assertFalse((self.apply / "terraform.tfvars").exists())
        self.assertFalse(list(self.apply.rglob("*.py")))

    def test_no_packages_is_valid_for_non_lambda_choices(self):
        PACKAGES.transfer(self.plan, self.artifact)
        PACKAGES.transfer(self.artifact, self.apply)
        self.assertFalse(self.apply.exists())


if __name__ == "__main__":
    unittest.main()
