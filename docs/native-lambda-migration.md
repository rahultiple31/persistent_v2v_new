# Native Dev Lambda deployment

`silence_guard-dev` and `UpdateSessionAttributes-dev` now use
`aws_lambda_function`, `filename`, and `source_code_hash`. Terraform uploads
their ZIP packages directly to Lambda. Neither module creates a deployment S3
bucket or a CloudFormation stack. Python sources, function names, role names,
log groups, and Connect associations are preserved.

Dev uses AWS provider `~> 6.21.0`, which supports Python 3.14. Shared modules
allow provider 5 and 6 so that the existing `dev-nsso` pin can remain on 5.100.
The existing pipeline choices and shared Connect state remain unchanged.

## First deployment after the old CloudFormation configuration

Use valid credentials for AWS account `518902362956`. Do not run concurrent
Connect-state deployments during the ownership transfer.

Initialize the existing backend from the repository root:

```bash
terraform -chdir=environments/dev init -reconfigure -upgrade \
  -backend-config='bucket=bts-cloud-terraform-tfstate' \
  -backend-config='key=terraform-state/dev/us-east-1/connect/terraform.tfstate' \
  -backend-config='region=us-east-1' \
  -backend-config='encrypt=true'
```

If an earlier deployment was attempted, run the migration once for each function:

```bash
python3 scripts/migrate-native-lambdas.py --function silence_guard-dev
python3 scripts/migrate-native-lambdas.py --function UpdateSessionAttributes-dev
```

The migration verifies the account and backend. For a successful legacy stack,
it applies `DeletionPolicy: Retain` to the existing function before removing
the stack, verifies that the Lambda remains, and imports it at its native
Terraform address. For a `ROLLBACK_COMPLETE` stack without a Lambda, it removes
only that failed stack. It never calls `delete-function`. If neither a stack nor
a Lambda exists, Terraform can create the function directly without migration.

Legacy deployment resources have `removed` blocks with `destroy = false`.
These prevent an ordinary Terraform plan from deleting the old stack's
function or deployment buckets while ownership is being transferred. Old S3
deployment buckets are retained but are no longer used. Their cleanup is separate.

Generate a fresh pipeline plan on `main`, using `targetEnvironment: dev` and
either `targetModule: silence_guard-dev` or
`targetModule: UpdateSessionAttributes-dev`. Review it, then run with
`terraformAction: apply`. Existing functions should be updated, not replaced.
Do not reuse a plan from before migration.

`UpdateSessionAttributes-dev` still requests reserved concurrency **300**.
AWS must have sufficient regional reservation capacity. The guard uses the
shared unreserved pool and retains `STRICT_MODE=false`.

## Subsequent deployments

Use the same pipeline choices. No migration script, S3 code upload, or
CloudFormation deployment is involved. Both handlers are unchanged. Invoke
`UpdateSessionAttributes-dev` after the Connect assistant block in the flow.
