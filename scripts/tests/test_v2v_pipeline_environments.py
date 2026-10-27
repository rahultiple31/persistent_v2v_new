"""Exercise the pipeline's Bash stages with local AWS and Terraform stubs."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

from scripts.tests.test_v2v_terraform_target import (
    BASH, ROOT, RESOURCE_MODULE_CHOICES, DESTROY_CHOICES, change, plan,
)


STUBS = r'''
curl() { printf '%s' '{"oidcToken":"test-token"}'; }
aws() { printf '%s\n' "$EXPECTED_ACCOUNT_ID"; }
python3() {
  if [[ "${1:-}" == */scripts/v2v-lambda-packages.py ]]; then
    printf 'packages <%s>\n' "$2" >> "$TEST_TRACE"
    return 0
  fi
  "$TEST_PYTHON" "$@"
}
terraform() {
  printf 'terraform' >> "$TEST_TRACE"
  printf ' <%s>' "$@" >> "$TEST_TRACE"
  printf '\n' >> "$TEST_TRACE"
  case "$1" in
    init) printf 'test-lock\n' > .terraform.lock.hcl ;;
    plan)
      local argument
      for argument in "$@"; do
        if [[ "$argument" == -out=* ]]; then
          printf 'test-plan\n' > "${argument#-out=}"
        fi
      done
      ;;
    output) printf '%s' '{}' ;;
    show) printf '%s' "$TEST_PLAN" ;;
    validate|apply) ;;
    *) return 1 ;;
  esac
}
'''


@unittest.skipUnless(BASH, "Bash is required to exercise the pipeline stages")
class V2VPipelineEnvironmentsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pipeline = (ROOT / "v2v-azure-pipeline.yml").read_text()
        scripts = re.findall(
            r"^          - bash: \|\n(.*?)(?=^            displayName:)",
            cls.pipeline, re.MULTILINE | re.DOTALL,
        )
        if len(scripts) != 2:
            raise AssertionError("Expected one Bash script for Plan and one for Apply")
        cls.stages = [textwrap.dedent(script) for script in scripts]

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def prepare(self, environment, choice):
        self.working_directory = self.root / environment / choice
        self.working_directory.mkdir(parents=True)
        variable_file = "terraform.tfvars" if environment == "v2v" else "terraform.dev.tfvars"
        (self.working_directory / variable_file).write_text("# Test values\n")
        self.trace = self.working_directory / "trace.txt"
        self.trace.write_text("")
        self.env = os.environ.copy()
        self.env.update({
            "TARGET_ENVIRONMENT": environment,
            "TARGET_MODULE": choice,
            "DEPLOYMENT_REGION": "us-east-1",
            "BACKEND_BUCKET": "bts-cloud-terraform-tfstate",
            "BACKEND_REGION": "us-east-1",
            "EXPECTED_ACCOUNT_ID": "518902362956",
            "AWS_DEV_OIDC_ROLE_ARN": "arn:aws:iam::518902362956:role/test",
            "BUILD_SOURCESDIRECTORY": ROOT.as_posix(),
            "BUILD_BUILDID": "123",
            "BUILD_SOURCEVERSION": "test-commit",
            "AGENT_TEMPDIRECTORY": self.working_directory.as_posix(),
            "PLAN_DIRECTORY": (self.working_directory / "artifact").as_posix(),
            "SYSTEM_ACCESSTOKEN": "test-access-token",
            "SYSTEM_OIDCREQUESTURI": "https://example.invalid/oidc",
            "TEST_TRACE": self.trace.as_posix(),
            "TEST_PYTHON": Path(sys.executable).as_posix(),
            "TEST_PLAN": json.dumps({"variables": {
                "environment": {"value": "v2v"},
                "enabled_modules": {"value": ["connect"]},
            }}),
        })

    def run_stage(self, stage):
        return subprocess.run(
            [BASH, "-s"], input=STUBS + self.stages[stage],
            cwd=self.working_directory, env=self.env,
            text=True, capture_output=True, timeout=30,
        )

    def test_environment_choices_route_to_the_corresponding_roots(self):
        self.assertIn("workingDirectory: '$(Build.SourcesDirectory)/environments/${{ parameters.targetEnvironment }}'", self.pipeline)
        self.assertEqual(self.pipeline.count("TARGET_ENVIRONMENT: ${{ parameters.targetEnvironment }}"), 2)
        environments = self.pipeline.split("  - name: targetEnvironment\n", 1)[1].split("# Set AWS_DEV_OIDC_ROLE_ARN", 1)[0]
        self.assertEqual(re.findall(r"^      - (.+)$", environments, re.MULTILINE), ["v2v", "v2v-resources"])
        source = (ROOT / "environments/v2v-resources/main.tf").read_text()
        modules = dict(re.findall(r'^module "([^"]+)" \{\s*(?:#[^\n]*\n\s*)?source\s*=\s*"([^"]+)"', source, re.MULTILINE))
        self.assertEqual(set(modules), RESOURCE_MODULE_CHOICES - {"all"})
        for name, path in modules.items():
            self.assertEqual(path, f"../../v2v-resource-modules/{name}")

    def test_all_resource_choices_keep_the_existing_state_and_apply_saved_plans(self):
        for choice in sorted(RESOURCE_MODULE_CHOICES):
            with self.subTest(choice=choice):
                self.prepare("v2v-resources", choice)
                for stage in (0, 1):
                    result = self.run_stage(stage)
                    self.assertEqual(result.returncode, 0, result.stderr)
                trace = self.trace.read_text()
                self.assertEqual(trace.count("<-backend-config=key=terraform-state/V2V-poc/terraform.tfstate>"), 2)
                plan_command = next(line for line in trace.splitlines() if line.startswith("terraform <plan>"))
                self.assertNotIn("<-destroy>", plan_command)
                self.assertIn("<-var-file=terraform.dev.tfvars>", plan_command)
                self.assertIn("<-var=aws_region=us-east-1>", plan_command)
                if choice == "all":
                    self.assertNotIn("<-target=", plan_command)
                else:
                    self.assertIn(f"<-target=module.{choice}>", plan_command)
                self.assertNotIn("enabled_modules", trace)
                self.assertNotIn("packages <", trace)
                apply_command = next(line for line in trace.splitlines() if line.startswith("terraform <apply>"))
                self.assertNotIn("<-target=", apply_command)
                self.assertIn("terraform.tfplan>", apply_command)

    def test_existing_v2v_choice_keeps_its_selector_and_lambda_packaging(self):
        self.prepare("v2v", "conversion_of_queue_metrics")
        for stage in (0, 1):
            result = self.run_stage(stage)
            self.assertEqual(result.returncode, 0, result.stderr)
        trace = self.trace.read_text()
        self.assertEqual(trace.count("<-backend-config=key=terraform-state/v2v/us-east-1/connect/terraform.tfstate>"), 2)
        self.assertIn('<-var=enabled_modules=["connect"]>', trace)
        self.assertIn("<-target=module.conversion_of_queue_metrics[0]>", trace)
        self.assertIn("<-target=aws_lambda_permission.queue_metrics_connect[0]>", trace)
        for command in ("build", "save", "restore"):
            self.assertIn(f"packages <{command}>", trace)
        self.assertNotIn("<-destroy>", trace)

    def test_destroy_choices_plan_and_apply_only_their_saved_targeted_plans(self):
        for choice, (group, modules) in DESTROY_CHOICES.items():
            with self.subTest(choice=choice):
                self.prepare("v2v", choice)
                self.env["TEST_PLAN"] = json.dumps(plan(group=group, changes=[
                    change(f"module.{name}[0].example_resource.this", ["delete"])
                    for name in modules
                ]))
                for stage in (0, 1):
                    result = self.run_stage(stage)
                    self.assertEqual(result.returncode, 0, result.stderr)
                trace = self.trace.read_text()
                self.assertEqual(trace.count(
                    f"<-backend-config=key=terraform-state/v2v/us-east-1/{group}/terraform.tfstate>"
                ), 2)
                plan_command = next(line for line in trace.splitlines() if line.startswith("terraform <plan>"))
                self.assertIn("<-destroy>", plan_command)
                self.assertIn(f'<-var=enabled_modules=["{group}"]>', plan_command)
                self.assertEqual(re.findall(r'<-target=([^>]+)>', plan_command), [
                    f"module.{name}[0]" for name in modules
                ])
                apply_command = next(line for line in trace.splitlines() if line.startswith("terraform <apply>"))
                self.assertIn("terraform.tfplan>", apply_command)
                self.assertNotIn("<-target=", apply_command)
                self.assertNotIn("<-destroy>", apply_command)
                self.assertNotIn("packages <", trace)
                self.assertNotIn("terraform <output>", trace)

    def test_destroy_plan_rejects_unrelated_deletion_before_apply(self):
        for choice, (group, _) in DESTROY_CHOICES.items():
            with self.subTest(choice=choice):
                self.prepare("v2v", choice)
                self.env["TEST_PLAN"] = json.dumps(plan(group=group, changes=[
                    change("module.btsgsd_ai_survey_agent[0].aws_cloudformation_stack.this", ["delete"]),
                ]))
                result = self.run_stage(0)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Refusing changes other than deletion", result.stderr)
                self.assertNotIn("terraform <apply>", self.trace.read_text())

    def test_destroy_apply_revalidates_plan_before_executing(self):
        for choice, (group, modules) in DESTROY_CHOICES.items():
            with self.subTest(choice=choice):
                self.prepare("v2v", choice)
                self.env["TEST_PLAN"] = json.dumps(plan(group=group))
                result = self.run_stage(0)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.trace.write_text("")
                self.env["TEST_PLAN"] = json.dumps(plan(group=group, changes=[
                    change(f"module.{modules[0]}[0].example_resource.this", ["create"]),
                ]))
                result = self.run_stage(1)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Refusing changes other than deletion", result.stderr)
                self.assertNotIn("terraform <apply>", self.trace.read_text())

    def test_choices_from_the_other_environment_fail_before_terraform_init(self):
        for environment, choice in (
            ("v2v-resources", "connect"), ("v2v", "ecr"),
            ("v2v-resources", "destroy_survey_ai"),
            ("v2v-resources", "destroy_survey_lex"),
        ):
            with self.subTest(environment=environment, choice=choice):
                self.prepare(environment, choice)
                for stage in (0, 1):
                    result = self.run_stage(stage)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Unsupported", result.stderr)
                self.assertEqual(self.trace.read_text(), "")

    def test_apply_rejects_saved_context_from_a_different_environment(self):
        self.prepare("v2v-resources", "ecr")
        result = self.run_stage(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        context = self.working_directory / "artifact/context.txt"
        context.write_text(context.read_text().replace("v2v-resources", "v2v"))
        self.trace.write_text("")
        result = self.run_stage(1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Saved plan does not match", result.stderr)
        self.assertEqual(self.trace.read_text(), "")


if __name__ == "__main__":
    unittest.main()
