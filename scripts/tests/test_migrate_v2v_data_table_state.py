"""Exercise state-only table migration without AWS or a real Terraform backend."""

from copy import deepcopy
import json
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from scripts import migrate_v2v_data_table_state as migration


def resource(address, identifier):
    resource_type = "aws_s3_object" if "aws_s3_object." in address else "aws_cloudformation_stack"
    position = address.rindex(resource_type + ".")
    module = address[:position].rstrip(".")
    name = address[position + len(resource_type) + 1:]
    instance = {"attributes": {"id": identifier}}
    if name.endswith("[0]"):
        name = name[:-3]
        instance["index_key"] = 0
    value = {"mode": "managed", "type": resource_type, "name": name, "instances": [instance]}
    if module:
        value["module"] = module
    return value


def fixture(migrated=False):
    return {
        "version": 4,
        "lineage": "connect-state-lineage",
        "serial": 7,
        "resources": [resource(pair[1 if migrated else 0], f"physical-{index}") for index, pair in enumerate(migration.MOVES)],
    }


class FakeTerraform:
    def __init__(self, state):
        self.state = deepcopy(state)
        self.commands = []
        self.fail_second_move = False

    def run(self, *command):
        self.commands.append(command)
        if command == ("terraform", "state", "pull"):
            return json.dumps(self.state)
        if command[:4] != ("terraform", "state", "mv", "-lock-timeout=5m"):
            raise AssertionError(f"Unexpected command: {command}")
        if self.fail_second_move and sum(call[1:3] == ("state", "mv") for call in self.commands) == 2:
            raise RuntimeError("Simulated move failure")
        old, new = command[4:]
        identifier = migration.resource_ids(self.state)[old]
        index = next(index for index, value in enumerate(self.state["resources"]) if value["instances"][0]["attributes"]["id"] == identifier)
        self.state["resources"][index] = resource(new, identifier)
        self.state["serial"] += 1
        return "Successfully moved 1 object."


class StateMigrationTests(unittest.TestCase):
    def setUp(self):
        self.output = io.StringIO()
        output_patch = patch("sys.stdout", self.output)
        output_patch.start()
        self.addCleanup(output_patch.stop)

    def test_preview_contains_only_three_expected_moves_and_no_state_values(self):
        state = fixture()
        plan = migration.make_plan(state)
        self.assertEqual([(move["from"], move["to"]) for move in plan["moves"]], list(migration.MOVES))
        self.assertEqual([move["status"] for move in plan["moves"]], ["move"] * 3)
        self.assertEqual(state, fixture())
        self.assertNotIn("physical-", json.dumps(plan))

    def test_already_migrated_and_absent_instances_are_skipped(self):
        state = fixture(migrated=True)
        state["resources"].pop()
        self.assertEqual([move["status"] for move in migration.make_plan(state)["moves"]], ["already_migrated", "already_migrated", "absent"])

    def test_both_addresses_are_rejected_before_moving_anything(self):
        state = fixture()
        state["resources"].append(resource(migration.MOVES[0][1], "duplicate"))
        with self.assertRaisesRegex(ValueError, "Both addresses exist"):
            migration.make_plan(state)

    def test_deposed_instances_are_rejected(self):
        state = fixture()
        state["resources"][0]["instances"][0]["deposed"] = "pending-replacement"
        with self.assertRaisesRegex(ValueError, "pending or duplicate"):
            migration.make_plan(state)

    def test_apply_backs_up_state_and_preserves_all_physical_ids(self):
        before = fixture()
        fake = FakeTerraform(before)
        with tempfile.TemporaryDirectory() as directory, patch.object(migration, "run", side_effect=fake.run):
            backups = Path(directory) / "backups"
            migration.apply_plan(migration.make_plan(before), backups)
            files = list(backups.glob("*.tfstate"))
            self.assertEqual(len(files), 1)
            self.assertEqual(json.loads(files[0].read_text()), before)
        self.assertEqual(migration.resource_ids(fake.state), {pair[1]: f"physical-{index}" for index, pair in enumerate(migration.MOVES)})
        self.assertEqual([call[4:] for call in fake.commands if call[1:3] == ("state", "mv")], list(migration.MOVES))

    def test_changed_state_or_tampered_preview_is_rejected(self):
        original = fixture()
        for variant in ("serial", "lineage", "contents", "preview"):
            with self.subTest(variant=variant):
                state = deepcopy(original)
                plan = migration.make_plan(original)
                if variant == "serial":
                    state["serial"] += 1
                elif variant == "lineage":
                    state["lineage"] = "different-state"
                elif variant == "contents":
                    state["resources"][0]["instances"][0]["attributes"]["id"] = "different-object"
                else:
                    plan["moves"][0]["to"] = "aws_cloudformation_stack.unrelated"
                fake = FakeTerraform(state)
                with tempfile.TemporaryDirectory() as directory, patch.object(migration, "run", side_effect=fake.run):
                    backups = Path(directory) / "backups"
                    with self.assertRaisesRegex(ValueError, "Run a new Plan"):
                        migration.apply_plan(plan, backups)
                    self.assertFalse(backups.exists())
                self.assertEqual(fake.commands, [("terraform", "state", "pull")])

    def test_fresh_preview_after_completed_migration_is_a_noop(self):
        fake = FakeTerraform(fixture(migrated=True))
        with tempfile.TemporaryDirectory() as directory, patch.object(migration, "run", side_effect=fake.run):
            backups = Path(directory) / "backups"
            migration.apply_plan(migration.make_plan(fake.state), backups)
            self.assertFalse(backups.exists())
        self.assertEqual(fake.commands, [("terraform", "state", "pull")])

    def test_partial_failure_can_be_resumed_from_a_fresh_preview(self):
        before = fixture()
        fake = FakeTerraform(before)
        fake.fail_second_move = True
        with tempfile.TemporaryDirectory() as directory, patch.object(migration, "run", side_effect=fake.run):
            backups = Path(directory)
            with self.assertRaisesRegex(RuntimeError, "Simulated"):
                migration.apply_plan(migration.make_plan(before), backups)
            self.assertIn(migration.MOVES[0][1], migration.resource_ids(fake.state))
            fake.fail_second_move = False
            migration.apply_plan(migration.make_plan(fake.state), backups)
        self.assertEqual(migration.resource_ids(fake.state), {pair[1]: f"physical-{index}" for index, pair in enumerate(migration.MOVES)})

    def test_context_requires_expected_account_and_connect_backend(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".terraform").mkdir()
            metadata = root / ".terraform/terraform.tfstate"
            metadata.write_text(json.dumps({"backend": {"type": "s3", "config": migration.BACKEND}}))
            with patch.object(migration, "run", return_value=migration.ACCOUNT_ID):
                migration.check_context(root)
            with patch.object(migration, "run", return_value="000000000000"):
                with self.assertRaisesRegex(ValueError, "Unexpected AWS account"):
                    migration.check_context(root)
            wrong = dict(migration.BACKEND, key="terraform-state/unrelated/terraform.tfstate")
            metadata.write_text(json.dumps({"backend": {"type": "s3", "config": wrong}}))
            with patch.object(migration, "run", return_value=migration.ACCOUNT_ID):
                with self.assertRaisesRegex(ValueError, "Connect S3 backend"):
                    migration.check_context(root)

    def test_plan_command_only_reads_state_and_writes_preview(self):
        fake = FakeTerraform(fixture())
        with tempfile.TemporaryDirectory() as directory, patch.object(migration, "run", side_effect=fake.run), patch.object(migration, "check_context"):
            preview = Path(directory) / "migration.json"
            with patch("sys.argv", ["migration", "--plan", str(preview)]):
                migration.main()
            self.assertEqual(json.loads(preview.read_text()), migration.make_plan(fake.state))
        self.assertEqual(fake.commands, [("terraform", "state", "pull")])


if __name__ == "__main__":
    unittest.main()
