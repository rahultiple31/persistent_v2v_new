"""One-time ownership transfer for the two Dev Lambdas; never deletes a Lambda.

Requires AWS CLI, Terraform, valid Dev credentials, and the initialized Connect
backend. Normal Lambda deployments do not run this migration script.
"""

import argparse
import json
import subprocess
import tempfile
from pathlib import Path


ACCOUNT_ID = "518902362956"
REGION = "us-east-1"
BACKEND_BUCKET = "bts-cloud-terraform-tfstate"
BACKEND_KEY = "terraform-state/dev/us-east-1/connect/terraform.tfstate"
STACK_NAMES = {
    "silence_guard-dev": "silence-guard-dev-lambda",
    "UpdateSessionAttributes-dev": "UpdateSessionAttributes-dev-lambda",
}


def run(command):
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout


def aws(service, operation, *arguments, missing=()):
    command = [
        "aws", service, operation, *arguments,
        "--region", REGION, "--output", "json", "--no-cli-pager",
    ]
    try:
        output = run(command)
    except RuntimeError as exc:
        if any(marker in str(exc) for marker in missing):
            return None
        raise
    return json.loads(output) if output.strip() else {}


def validate_backend(directory):
    metadata = directory / ".terraform" / "terraform.tfstate"
    if not metadata.is_file():
        raise RuntimeError("Initialize the Dev Connect S3 backend before migration.")
    backend = json.loads(metadata.read_text(encoding="utf-8"))["backend"]
    config = backend.get("config") or {}
    if (
        backend.get("type") != "s3"
        or config.get("bucket") != BACKEND_BUCKET
        or config.get("key") != BACKEND_KEY
    ):
        raise RuntimeError("Migration requires the existing Dev Connect Terraform state.")


def retained_template(template, function_name):
    if isinstance(template, str):
        template = json.loads(template)
    resources = template.get("Resources", {})
    if set(resources) != {"Function"}:
        raise RuntimeError("Expected a legacy stack containing only the Function resource.")
    resource = resources["Function"]
    if (
        resource.get("Type") != "AWS::Lambda::Function"
        or resource.get("Properties", {}).get("FunctionName") != function_name
    ):
        raise RuntimeError("Legacy stack does not own the expected Lambda name.")
    resource["DeletionPolicy"] = "Retain"
    resource["UpdateReplacePolicy"] = "Retain"
    return template


def detach_stack(stack, function_name, function_exists):
    status = stack["StackStatus"]
    stack_id = stack["StackId"]
    if not stack_id.startswith(f"arn:aws:cloudformation:{REGION}:{ACCOUNT_ID}:stack/"):
        raise RuntimeError("Unexpected legacy stack account or region.")
    if status == "ROLLBACK_COMPLETE":
        if function_exists:
            raise RuntimeError(
                "Failed stack and existing Lambda need an ownership review; nothing deleted."
            )
    elif status in {"CREATE_COMPLETE", "UPDATE_COMPLETE", "UPDATE_ROLLBACK_COMPLETE"}:
        template = aws(
            "cloudformation", "get-template", "--stack-name", stack_id,
            "--template-stage", "Original",
        )["TemplateBody"]
        template = retained_template(template, function_name)
        with tempfile.TemporaryDirectory(prefix="native-lambda-migration-") as temporary:
            path = Path(temporary) / "retain-function.json"
            path.write_text(json.dumps(template), encoding="utf-8")
            arguments = ["--stack-name", stack_id, "--template-body", "file://" + str(path)]
            parameters = stack.get("Parameters") or []
            if parameters:
                arguments.extend([
                    "--parameters", json.dumps([
                        {"ParameterKey": p["ParameterKey"], "UsePreviousValue": True}
                        for p in parameters
                    ]),
                ])
            if stack.get("Capabilities"):
                arguments.extend(["--capabilities", *stack["Capabilities"]])
            try:
                aws("cloudformation", "update-stack", *arguments)
            except RuntimeError as exc:
                if "No updates are to be performed" not in str(exc):
                    raise
            else:
                aws("cloudformation", "wait", "stack-update-complete", "--stack-name", stack_id)
        print(f"{function_name}: retention policy applied to the old stack.", flush=True)
    else:
        raise RuntimeError(f"Legacy stack must be stable before migration; found {status}.")

    aws("cloudformation", "delete-stack", "--stack-name", stack_id)
    aws("cloudformation", "wait", "stack-delete-complete", "--stack-name", stack_id)
    print(f"{function_name}: legacy stack removed; Lambda retention preserved.", flush=True)


def migrate(function_name, directory, terraform):
    if aws("sts", "get-caller-identity")["Account"] != ACCOUNT_ID:
        raise RuntimeError("AWS credentials must belong to the confirmed Dev account.")
    validate_backend(directory)
    tf = [terraform, "-chdir=" + str(directory)]
    addresses = set(run([*tf, "state", "list"]).splitlines())
    module = f"module.{function_name}[0]"
    address = module + ".aws_lambda_function.this"
    function = aws(
        "lambda", "get-function", "--function-name", function_name,
        missing=("ResourceNotFoundException",),
    )
    if function and address not in addresses:
        required = {module + ".aws_iam_role.execution", module + ".aws_cloudwatch_log_group.this"}
        if not required.issubset(addresses):
            raise RuntimeError("Existing Lambda role/log group are not in Connect state; review imports first.")
    stack_result = aws(
        "cloudformation", "describe-stacks", "--stack-name", STACK_NAMES[function_name],
        missing=("does not exist",),
    )
    if stack_result:
        detach_stack(stack_result["Stacks"][0], function_name, function is not None)
    after = aws(
        "lambda", "get-function", "--function-name", function_name,
        missing=("ResourceNotFoundException",),
    )
    if function and (not after or after["Configuration"]["FunctionArn"] != function["Configuration"]["FunctionArn"]):
        raise RuntimeError("Lambda retention could not be verified; stop before Terraform apply.")
    if after and address not in addresses:
        run([
            *tf, "import", "-input=false", '-var=enabled_modules=["connect"]',
            address, function_name,
        ])
        print(f"{function_name}: imported into the native Terraform resource.", flush=True)
    elif after:
        print(f"{function_name}: native Terraform ownership already exists.", flush=True)
    else:
        print(f"{function_name}: no existing Lambda; the native Terraform plan will create it.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--function", required=True, choices=sorted(STACK_NAMES))
    parser.add_argument(
        "--terraform-dir", type=Path,
        default=Path(__file__).resolve().parents[1] / "environments" / "dev",
    )
    parser.add_argument("--terraform-executable", default="terraform")
    args = parser.parse_args()
    migrate(args.function, args.terraform_dir.resolve(), args.terraform_executable)


if __name__ == "__main__":
    main()
