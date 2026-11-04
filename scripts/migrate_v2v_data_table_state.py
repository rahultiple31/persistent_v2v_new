"""Preview or apply the three V2V data-table state moves without deploying resources."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ACCOUNT_ID = "518902362956"
BACKEND = {
    "bucket": "bts-cloud-terraform-tfstate",
    "key": "terraform-state/v2v/us-east-1/connect/terraform.tfstate",
    "region": "us-east-1",
}
MOVES = (
    (
        "aws_cloudformation_stack.bts_gsd_customer_number_data_table[0]",
        "module.bts_gsd_customer_number_data_table[0].aws_cloudformation_stack.this",
    ),
    (
        "aws_cloudformation_stack.survey_data_table[0]",
        "module.survey_data_table[0].aws_cloudformation_stack.this",
    ),
    (
        "aws_s3_object.survey_table_template[0]",
        "module.survey_data_table[0].aws_s3_object.template[0]",
    ),
)


def run(*command):
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f"Command failed: {' '.join(command)}")
    return result.stdout


def check_context(directory):
    account = run("aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text").strip()
    if account != ACCOUNT_ID:
        raise ValueError(f"Unexpected AWS account: {account}")
    metadata = json.loads((directory / ".terraform/terraform.tfstate").read_text(encoding="utf-8"))
    backend = metadata.get("backend", {})
    config = backend.get("config", {})
    if backend.get("type") != "s3" or any(config.get(key) != value for key, value in BACKEND.items()):
        raise ValueError("Initialize the existing V2V Connect S3 backend before migrating state.")


def resource_ids(state):
    tracked = {address for pair in MOVES for address in pair}
    resources = {}
    for resource in state.get("resources", []):
        if resource.get("mode") != "managed":
            continue
        prefix = resource.get("module", "")
        address = (prefix + "." if prefix else "") + resource["type"] + "." + resource["name"]
        for instance in resource.get("instances", []):
            current = address
            if "index_key" in instance:
                current += "[" + json.dumps(instance["index_key"]) + "]"
            if current not in tracked:
                continue
            if instance.get("deposed") or current in resources:
                raise ValueError(f"Resolve pending or duplicate instances before migrating: {current}")
            resources[current] = instance.get("attributes", {}).get("id")
    return resources


def make_plan(state):
    if not state.get("lineage") or type(state.get("serial")) is not int:
        raise ValueError("The Connect state has no valid lineage or serial.")
    resources = resource_ids(state)
    moves = []
    for old, new in MOVES:
        if old in resources and new in resources:
            raise ValueError(f"Both addresses exist; resolve the duplicate: {old} -> {new}")
        status = "move" if old in resources else "already_migrated" if new in resources else "absent"
        moves.append({"from": old, "to": new, "status": status})
    digest = hashlib.sha256(json.dumps(state, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()
    return {
        "format_version": 1,
        "account_id": ACCOUNT_ID,
        "backend": BACKEND,
        "state_lineage": state["lineage"],
        "state_serial": state["serial"],
        "state_sha256": digest,
        "moves": moves,
    }


def read_state():
    return json.loads(run("terraform", "state", "pull"))


def apply_plan(plan, backup_directory):
    state = read_state()
    if plan != make_plan(state):
        raise ValueError("The state or migration preview changed. Run a new Plan before applying.")
    pending = [move for move in plan["moves"] if move["status"] == "move"]
    if not pending:
        print("No pending data-table state moves.")
        return

    backup_directory.mkdir(parents=True, exist_ok=True)
    prefix = "connect-before-table-move-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-")
    descriptor, backup = tempfile.mkstemp(prefix=prefix, suffix=".tfstate", dir=backup_directory)
    with os.fdopen(descriptor, "w", encoding="utf-8") as file:
        json.dump(state, file, indent=2)
        file.write("\n")
    print(f"State backup: {backup}")

    original_ids = resource_ids(state)
    for move in pending:
        run("terraform", "state", "mv", "-lock-timeout=5m", move["from"], move["to"])
        print(f"Migrated: {move['from']} -> {move['to']}")

    migrated_ids = resource_ids(read_state())
    for move in pending:
        if move["from"] in migrated_ids or move["to"] not in migrated_ids or migrated_ids[move["to"]] != original_ids[move["from"]]:
            raise ValueError("State migration verification failed. Retain the backup and review the state.")
    print("Verified all migrated resource IDs. No AWS resources were deployed or deleted.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--plan", type=Path, help="Write a read-only migration preview.")
    mode.add_argument("--apply", type=Path, help="Apply the saved migration preview.")
    parser.add_argument("--backup-directory", type=Path, default=Path("state-migration-backups"))
    args = parser.parse_args()
    check_context(Path.cwd())
    if args.plan:
        plan = make_plan(read_state())
        args.plan.parent.mkdir(parents=True, exist_ok=True)
        args.plan.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
        for move in plan["moves"]:
            print(f"{move['status']}: {move['from']} -> {move['to']}")
        print("Preview only; Terraform state was not changed.")
    else:
        apply_plan(json.loads(args.apply.read_text(encoding="utf-8")), args.backup_directory)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, RuntimeError) as error:
        print(f"V2V data-table state migration failed: {error}", file=sys.stderr)
        sys.exit(1)
