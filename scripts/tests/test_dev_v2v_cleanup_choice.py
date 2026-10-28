"""Check the complete V2V cleanup choices and their plan restrictions."""

import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
if os.name == "nt":
    git_bash = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
    BASH = str(git_bash) if git_bash.is_file() else None
else:
    BASH = shutil.which("bash")


SPEC = importlib.util.spec_from_file_location(
    "validate_dev_v2v_cleanup_plan", ROOT / "scripts/validate-dev-v2v-cleanup-plan.py"
)
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


def resource(address, actions, *, before=None, after=None):
    return {
        "address": address,
        "change": {"actions": actions, "before": before, "after": after},
    }


def plan(environment="dev", changes=(), *, prepared=True, destroy=True):
    return {
        "variables": {
            "environment": {"value": environment},
            "enabled_modules": {"value": ["v2v"]},
            "force_destroy_v2v_buckets": {"value": prepared},
            "destroy_v2v_stack": {"value": destroy},
        },
        "resource_changes": list(changes),
    }


BUCKET = "module.s3_v2v[0].aws_s3_bucket.v2v"
LOG_BUCKET = "module.s3_v2v[0].aws_s3_bucket.v2v_logs"
ALL_MODULE_CHANGES = [
    resource(BUCKET, ["delete"], before={"force_destroy": True}),
    resource(LOG_BUCKET, ["delete"], before={"force_destroy": True}),
    resource("module.cloudfront_v2v[0].aws_cloudfront_distribution.v2v", ["delete"]),
    resource("module.cognito_v2v[0].aws_cognito_user_pool.this", ["delete"]),
    resource("module.iam_v2v[0].aws_iam_role.authenticated", ["delete"]),
    resource("module.ssm_v2v[0].aws_ssm_parameter.this[\"ssoEnabled\"]", ["delete"]),
    resource("terraform_data.v2v_settings[0]", ["delete"]),
]


class V2VCleanupPlanTests(unittest.TestCase):
    def test_preparation_allows_only_force_destroy_bucket_updates(self):
        updates = [
            resource(BUCKET, ["update"], before={"force_destroy": False}, after={"force_destroy": True}),
            resource(LOG_BUCKET, ["update"], before={"force_destroy": False}, after={"force_destroy": True}),
            resource("module.cloudfront_v2v[0].aws_cloudfront_distribution.v2v", ["no-op"]),
        ]
        self.assertEqual(VALIDATOR.validate(plan(changes=updates, destroy=False), "prepare-destroy-v2v", "dev"), 0)
        for extra in (
            resource("module.cognito_v2v[0].aws_cognito_user_pool.this", ["delete"]),
            resource(BUCKET, ["update"], before={"force_destroy": False}, after={"force_destroy": False}),
            resource(BUCKET, ["update"], before={"force_destroy": False, "tags": {"a": "b"}}, after={"force_destroy": True, "tags": {"a": "c"}}),
            resource("module.s3_v2v[0].aws_s3_bucket_policy.v2v", ["update"]),
        ):
            with self.subTest(extra=extra):
                with self.assertRaises(ValueError):
                    VALIDATOR.validate(plan(changes=updates + [extra], destroy=False), "prepare-destroy-v2v", "dev")

        with self.assertRaises(ValueError):
            VALIDATOR.validate(plan(changes=updates), "prepare-destroy-v2v", "dev")

    def test_destroy_allows_five_modules_and_root_marker(self):
        for environment in ("dev", "dev-nsso"):
            with self.subTest(environment=environment):
                self.assertEqual(
                    VALIDATOR.validate(plan(environment, ALL_MODULE_CHANGES), "destroy-v2v-stack", environment),
                    len(ALL_MODULE_CHANGES),
                )

    def test_destroy_accepts_legacy_moved_addresses_and_state_only_asset_removal(self):
        changes = [
            resource("module.s3[0].aws_s3_bucket.webapp", ["delete"], before={"force_destroy": True}),
            resource("module.cloudfront[0].aws_cloudfront_distribution.webapp", ["delete"]),
            resource("module.cognito[0].aws_cognito_user_pool.this", ["delete"]),
            resource("module.iam[0].aws_iam_role.authenticated", ["delete"]),
            resource("module.ssm[0].aws_ssm_parameter.this[\"ssoEnabled\"]", ["delete"]),
            resource("module.s3[0].aws_s3_object.webapp_assets", ["forget"]),
        ]
        self.assertEqual(VALIDATOR.validate(plan(changes=changes), "destroy-v2v-stack", "dev"), 5)

    def test_destroy_rejects_unprepared_buckets_or_other_actions(self):
        invalid_changes = (
            [resource(BUCKET, ["delete"], before={"force_destroy": False})],
            [resource("module.connect_us_east_1[0].aws_connect_instance.this", ["delete"])],
            [resource("module.cloudfront_v2v[0].aws_cloudfront_distribution.v2v", ["create"])],
            [resource("module.cognito_v2v[0].aws_cognito_user_pool.this", ["delete", "create"])],
        )
        for extra in invalid_changes:
            with self.subTest(extra=extra):
                with self.assertRaises(ValueError):
                    VALIDATOR.validate(plan(changes=ALL_MODULE_CHANGES + extra), "destroy-v2v-stack", "dev")

    def test_destroy_rejects_empty_or_wrong_environment_or_group(self):
        with self.assertRaises(ValueError):
            VALIDATOR.validate(plan(), "destroy-v2v-stack", "dev")
        with self.assertRaises(ValueError):
            VALIDATOR.validate(plan("dev-nsso", ALL_MODULE_CHANGES), "destroy-v2v-stack", "dev")
        with self.assertRaises(ValueError):
            VALIDATOR.validate(plan(changes=ALL_MODULE_CHANGES, prepared=False), "destroy-v2v-stack", "dev")
        with self.assertRaises(ValueError):
            VALIDATOR.validate(plan(changes=ALL_MODULE_CHANGES, destroy=False), "destroy-v2v-stack", "dev")


@unittest.skipUnless(BASH, "Bash is required to test the pipeline selector")
class V2VCleanupSelectorTests(unittest.TestCase):
    def test_both_choices_use_each_environments_v2v_state(self):
        for environment in ("dev", "dev-nsso"):
            for choice in ("prepare-destroy-v2v", "destroy-v2v-stack"):
                with self.subTest(environment=environment, choice=choice):
                    env = os.environ.copy()
                    env.update({"TEST_ENVIRONMENT": environment, "TEST_CHOICE": choice})
                    result = subprocess.run(
                        [BASH, "-s"],
                        input='''set -euo pipefail
source scripts/terraform-target.sh "$TEST_CHOICE" "$TEST_ENVIRONMENT" us-east-1
printf '%s\\n' "$TERRAFORM_STATE_MODULE" "$TERRAFORM_BACKEND_KEY" "${TERRAFORM_PLAN_ARGS[@]}"
''',
                        cwd=ROOT,
                        env=env,
                        text=True,
                        capture_output=True,
                        timeout=30,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    lines = result.stdout.splitlines()
                    self.assertEqual(lines[:4], [
                        "v2v",
                        f"terraform-state/{environment}/us-east-1/v2v/terraform.tfstate",
                        '-var=enabled_modules=["v2v"]',
                        "-var=force_destroy_v2v_buckets=true",
                    ])
                    self.assertEqual(lines[4:], [
                        f"-var=destroy_v2v_stack={'true' if choice == 'destroy-v2v-stack' else 'false'}"
                    ])

    def test_pipeline_exposes_both_choices(self):
        pipeline = (ROOT / "azure-pipelines.yml").read_text(encoding="utf-8")
        self.assertIn("      - prepare-destroy-v2v\n", pipeline)
        self.assertIn("      - destroy-v2v-stack\n", pipeline)
        self.assertNotIn("      - v2v\n", pipeline)
        self.assertNotIn("      - destroy-cloudfront-cognito\n", pipeline)

    def test_v2v_modules_are_disabled_by_default_in_both_roots(self):
        for environment in ("dev", "dev-nsso"):
            with self.subTest(environment=environment):
                variables = (ROOT / f"environments/{environment}/variables.tf").read_text(encoding="utf-8")
                main = (ROOT / f"environments/{environment}/main.tf").read_text(encoding="utf-8")
                self.assertRegex(variables, r'variable "destroy_v2v_stack" \{[^}]*default\s+= true')
                self.assertIn('contains(local.enabled_module_set, "v2v") && !var.destroy_v2v_stack', main)
                for module_name in ("s3_v2v", "cloudfront_v2v", "cognito_v2v", "iam_v2v", "ssm_v2v"):
                    self.assertRegex(
                        main,
                        rf'module "{module_name}" \{{\s*count\s*= local\.deploy_v2v \? 1 : 0',
                    )
                marker = (ROOT / f"environments/{environment}/v2v.tf").read_text(encoding="utf-8")
                self.assertIn("count = local.deploy_v2v || local.deploy_proxy ? 1 : 0", marker)

    def test_normal_v2v_choice_is_rejected(self):
        env = os.environ.copy()
        result = subprocess.run(
            [BASH, "-c", "source scripts/terraform-target.sh v2v dev us-east-1"],
            cwd=ROOT, env=env, text=True, capture_output=True, timeout=30,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("V2V deployment is retired", result.stderr)


if __name__ == "__main__":
    unittest.main()
