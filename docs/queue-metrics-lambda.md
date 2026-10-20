# Queue metrics Lambda

The dev Connect selection deploys `conversionOfQueueMetrics-dev` from
`modules/conversionOfQueueMetrics-dev`. The handler source is
`environments/dev/metadata/conversionOfQueueMetrics-dev_lambda/lambda_function.py`. Terraform reads the
prebuilt `lambda_function.zip` in the same directory using `filename` and
`filebase64sha256`, then uploads it directly to Lambda. This module does not
use `archive_file`. The dev pipeline builds the ZIP from the checked-out source
before Terraform runs and preserves it in the plan artifact. Apply restores
the exact planned ZIP. The ZIP is also allowed by `.gitignore` for local use.

After changing the Python source, rebuild the ZIP from the repository root
before local Terraform plan/apply:

```bash
python3 -m zipfile -c environments/dev/metadata/conversionOfQueueMetrics-dev_lambda/lambda_function.zip environments/dev/metadata/conversionOfQueueMetrics-dev_lambda/lambda_function.py
```

The ZIP must contain `lambda_function.py` at its root. The handler remains
`lambda_function.lambda_handler`.

The function uses Python 3.14, 128 MB memory, a 7-second timeout, 512 MB ephemeral
storage, and `/aws/lambda/conversionOfQueueMetrics-dev` with 14-day log retention.
Environment variables are `TableName=queueInfo`, `LOG_LEVEL=DEBUG`, and
`TTL_SECONDS=86400`.

The existing role `conversionOfQueueMetrics-role-ox32eazp` must trust
`lambda.amazonaws.com`. The existing `queueInfo` table must have a string
partition key named `callId`. The module grants the role `GetItem` and
`UpdateItem` on that table and log writes to the configured log group.
For automatic expiration, enable DynamoDB TTL on the existing table's `ttl`
attribute; writing the attribute alone does not enable TTL processing.

If the named log group or Lambda is already deployed outside this Terraform
configuration, import it before applying rather than attempting to create it
again.

The handler accepts Amazon Connect invocation parameters `invocationType`,
`queue_time`, and `positionInQueue`. `putQueue` stores entry time and TTL;
`getEWT` subtracts elapsed time from `queue_time` and returns flat string values.

The `BTSGSD_Abbvie_CustomerQueueFlow` deployment renders the supplied JSON's
`conversionOfQueueMetrics` reference as `conversionOfQueueMetrics-dev`.
Terraform grants Connect invocation permission scoped to the managed instance
and account, then associates the Lambda with that instance. The rendered flow
references the association's function ARN so dependency resolution waits for
that association. The stored JSON retains the original export.

The flow keeps its existing resource address,
`module.connect_us_east_1[0].aws_connect_contact_flow.imported["customer_queue"]`.
The display name is now exactly `BTSGSD_Abbvie_CustomerQueueFlow`.
Existing prompt, voicemail module, and data-table resolution still uses
`connect_customer_queue_dependency_names` and the managed survey table.
The Lex bot aliases in the export must exist and be associated with the instance.

Deploy from `main` using pipeline environment `dev`, module `connect`, and action
`plan`; review the changes, then run with action `apply` for a fresh plan and
deployment. If the metrics Lambda association is already present outside this
Terraform state, import it into
`aws_connect_lambda_function_association.queue_metrics[0]` using the Connect
backend before applying. Reuse or import an existing matching Lambda permission
instead of creating a duplicate statement.

Outputs are `conversion_of_queue_metrics_lambda_name`,
`conversion_of_queue_metrics_lambda_arn`, and
`conversion_of_queue_metrics_iam_role_arn`, returning null when Connect is disabled.

With `boto3` installed, run the handler tests from the repository root:

```bash
python3 -m unittest discover -s modules/conversionOfQueueMetrics-dev/tests -v
terraform -chdir=modules/conversionOfQueueMetrics-dev init -backend=false
terraform -chdir=modules/conversionOfQueueMetrics-dev test
```

Terraform tests mock AWS and read the supplied ZIP; they create no AWS resources.
