import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
if os.name == "nt":
    git_bash = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
    BASH = str(git_bash) if git_bash.is_file() else None
else:
    BASH = shutil.which("bash")


def change(address, actions, mode="managed"):
    return {"address": address, "mode": mode, "change": {"actions": actions}}


def plan(group="connect-resources", changes=(), environment="v2v"):
    return {
        "variables": {
            "environment": {"value": environment},
            "enabled_modules": {"value": [group]},
        },
        "resource_changes": list(changes),
    }


@unittest.skipUnless(BASH, "Bash is required to exercise the pipeline selector")
class V2VTerraformTargetTests(unittest.TestCase):
    def run_selector(self, target, saved_plan=None):
        env = os.environ.copy()
        env.update({
            "V2V_TEST_TARGET": target,
            "V2V_TEST_PYTHON": sys.executable.replace("\\", "/"),
            "V2V_TEST_PLAN": json.dumps(saved_plan),
            "V2V_TEST_VALIDATE": "1" if saved_plan is not None else "0",
        })
        return subprocess.run(
            [BASH, "-s"],
            input='''set -euo pipefail
source scripts/terraform-target-v2v.sh "$V2V_TEST_TARGET" v2v us-east-1
if [ "$V2V_TEST_VALIDATE" = 1 ]; then
  terraform() { printf '%s' "$V2V_TEST_PLAN"; }
  python3() { "$V2V_TEST_PYTHON" "$@"; }
  validate_v2v_target_plan fixture.tfplan
else
  printf '%s\\n' "$TERRAFORM_STATE_MODULE" "$TERRAFORM_BACKEND_KEY" "${TERRAFORM_PLAN_ARGS[1]}"
fi
''',
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def test_choices_use_separate_state_and_enable_only_their_own_group(self):
        for target, group in (
            ("connect-resources", "connect-resources"),
            ("connect", "connect"),
            ("connect_queue", "connect"),
            ("lambda", "lambda"),
            ("dynamodb", "dynamodb"),
            ("v2v", "v2v"),
        ):
            with self.subTest(target=target):
                result = self.run_selector(target)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [
                    group,
                    f"terraform-state/v2v/us-east-1/{group}/terraform.tfstate",
                    f'-var=enabled_modules=["{group}"]',
                ])

    def test_allows_changes_inside_standalone_module_and_read_only_lookups(self):
        saved_plan = plan(changes=[
            change("module.connect_resources[0].aws_connect_queue.us_out", ["create"]),
            change("module.connect_resources[0].aws_connect_user.this[\"agent\"]", ["update"]),
            change("data.aws_connect_instance.target[0]", ["read"], mode="data"),
            change("module.connect_queue[0].aws_connect_queue.queue", ["no-op"]),
        ])
        result = self.run_selector("connect-resources", saved_plan)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_creates_updates_deletes_and_replacements_outside_module(self):
        for actions in (["create"], ["update"], ["delete"], ["delete", "create"]):
            with self.subTest(actions=actions):
                result = self.run_selector("connect-resources", plan(changes=[
                    change("module.connect_queue[0].aws_connect_queue.queue", actions),
                ]))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Refusing changes outside connect_resources", result.stderr)

    def test_rejects_root_resources_and_other_module_instances(self):
        for address in (
            "terraform_data.example",
            "module.connect_resources[1].aws_connect_queue.us_out",
            "module.connect_resources_extra[0].aws_connect_queue.us_out",
        ):
            with self.subTest(address=address):
                result = self.run_selector("connect-resources", plan(changes=[
                    change(address, ["create"]),
                ]))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Refusing changes outside connect_resources", result.stderr)

    def test_rejects_connect_group_deleting_standalone_module_from_old_state(self):
        result = self.run_selector("connect", plan(group="connect", changes=[
            change("module.connect_resources[0].aws_connect_queue.us_out", ["delete"]),
        ]))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Move connect_resources into its dedicated state", result.stderr)

    def test_allows_regular_connect_group_changes(self):
        result = self.run_selector("connect", plan(group="connect", changes=[
            change("module.connect_queue[0].aws_connect_queue.queue", ["update"]),
        ]))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_wrong_plan_environment_or_module_group(self):
        for saved_plan, message in (
            (plan(environment="dev"), "Plan environment does not match"),
            (plan(group="connect"), "Plan module group does not match"),
        ):
            with self.subTest(message=message):
                result = self.run_selector("connect-resources", saved_plan)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)


if __name__ == "__main__":
    unittest.main()
