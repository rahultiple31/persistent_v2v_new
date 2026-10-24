import json
import os
import re
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
    def run_selector(self, target, saved_plan=None, details=False):
        env = os.environ.copy()
        env.update({
            "V2V_TEST_TARGET": target,
            "V2V_TEST_DETAILS": "1" if details else "0",
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
elif [ "$V2V_TEST_DETAILS" = 1 ]; then
  printf '%s\\n' "$TERRAFORM_STATE_MODULE" "$TERRAFORM_BACKEND_KEY" "${TERRAFORM_PLAN_ARGS[@]}"
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

    def test_every_pipeline_choice_resolves_to_existing_module_or_group(self):
        pipeline = (ROOT / "v2v-azure-pipeline.yml").read_text()
        values = pipeline.split("    values:\n", 1)[1].split("  - name: terraformAction", 1)[0]
        choices = re.findall(r"^      - (.+)$", values, re.MULTILINE)
        self.assertEqual(len(choices), len(set(choices)))
        selector = (ROOT / "scripts/terraform-target-v2v.sh").read_text()
        registry = selector.split("done <<'V2V_CHOICES'\n", 1)[1].split("\nV2V_CHOICES", 1)[0]
        self.assertEqual(set(choices), {row.split("|")[0] for row in registry.splitlines()})
        modules = set()
        for path in (ROOT / "environments/v2v").glob("*.tf"):
            modules.update(re.findall(r'^module "([^"]+)"', path.read_text(encoding="utf-8"), re.MULTILINE))
        legacy = {
            "btsgsd-v2v-us-snow": "lambda-snow-btsgsd-dev",
            "btsgsd-v2v-us-servicenow_interaction": "lambda-servicenow-interaction",
            "btsgsd-v2v-us-nextthink_handoff": "lambda-nextthink-handoff",
        }
        aliases = {
            "lambda": "lambda_us_east_1", "dynamodb": "queue_info_dynamodb",
            "btsgsd-intent-kb": "s3_intent_kb", "connect-resources": "connect_resources",
            "BTSGSD-V2V-US-lex-QueueFlow-Callback": "lex_queueflow_callback",
            "BTSGSD-V2V-US-lex-yesNo": "lex_yesno",
        }
        for choice in choices:
            with self.subTest(choice=choice):
                result = self.run_selector(choice, details=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                group, backend, *arguments = result.stdout.splitlines()
                state = legacy.get(group, group)
                self.assertEqual(backend, f"terraform-state/v2v/us-east-1/{state}/terraform.tfstate")
                self.assertIn(f'-var=enabled_modules=["{group}"]', arguments)
                targets = [a for a in arguments if a.startswith("-target=")]
                if choice in ("connect", "v2v", "code-signing"):
                    self.assertEqual(targets, [])
                else:
                    module = aliases.get(choice, choice)
                    self.assertIn(module, modules)
                    self.assertEqual(targets, [f"-target=module.{module}[0]"])

    def test_unknown_choice_fails(self):
        result = self.run_selector("unknown-module")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsupported V2V module", result.stderr)

    def test_choices_use_separate_state_and_enable_only_their_own_group(self):
        for target, group in (
            ("connect-resources", "connect-resources"),
            ("connect", "connect"),
            ("connect_queue", "connect"),
            ("BTSGSD-V2V-US-UpdateSessionAttributes", "connect"),
            ("lambda", "lambda"),
            ("dynamodb", "dynamodb"),
            ("v2v", "v2v"),
            ("code-signing", "code-signing"),
            ("signing_profile", "code-signing"),
            ("code_signing_config", "code-signing"),
        ):
            with self.subTest(target=target):
                result = self.run_selector(target)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [
                    group,
                    f"terraform-state/v2v/us-east-1/{group}/terraform.tfstate",
                    f'-var=enabled_modules=["{group}"]',
                ])

    def test_lambda_renames_retain_state_and_accept_plans_for_new_targets(self):
        for target, state in (
            ("BTSGSD-V2V-US-SNOW", "lambda-snow-btsgsd-dev"),
            ("BTSGSD-V2V-US-ServiceNow_Interaction", "lambda-servicenow-interaction"),
            ("BTSGSD-V2V-US-Nextthink_Handoff", "lambda-nextthink-handoff"),
        ):
            with self.subTest(target=target):
                group = target.lower()
                result = self.run_selector(target)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [
                    group,
                    f"terraform-state/v2v/us-east-1/{state}/terraform.tfstate",
                    f'-var=enabled_modules=["{group}"]',
                ])
                result = self.run_selector(target, plan(group=group))
                self.assertEqual(result.returncode, 0, result.stderr)

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

    def test_signing_choices_allow_both_modules_in_one_state(self):
        saved_plan = plan(group="code-signing", changes=[
            change("module.signing_profile[0].aws_signer_signing_profile.this[0]", ["create"]),
            change("module.code_signing_config[0].aws_lambda_code_signing_config.this", ["create"]),
        ])
        for target in ("code-signing", "signing_profile", "code_signing_config"):
            with self.subTest(target=target):
                result = self.run_selector(target, saved_plan)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_signing_group_rejects_unrelated_resource_changes(self):
        for address in (
            "module.connect_queue[0].aws_connect_queue.queue",
            "module.signing_profile[1].aws_signer_signing_profile.this[0]",
            "module.signing_profile_extra[0].aws_signer_signing_profile.this[0]",
        ):
            for actions in (["create"], ["update"], ["delete"], ["delete", "create"]):
                with self.subTest(address=address, actions=actions):
                    result = self.run_selector("code_signing_config", plan(group="code-signing", changes=[
                        change(address, actions),
                    ]))
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("Refusing changes outside the code-signing modules", result.stderr)

    def test_other_groups_cannot_modify_signing_resources_from_old_states(self):
        for address in (
            "module.signing_profile[0].aws_signer_signing_profile.this[0]",
            "module.code_signing_config[0].aws_lambda_code_signing_config.this",
        ):
            with self.subTest(address=address):
                result = self.run_selector("connect", plan(group="connect", changes=[
                    change(address, ["delete"]),
                ]))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Move the signing modules into the dedicated code-signing state", result.stderr)


if __name__ == "__main__":
    unittest.main()
