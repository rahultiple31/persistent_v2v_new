# Queue metrics Lambda

The dev Connect selection deploys `conversionOfQueueMetrics-dev` from
`modules/conversionOfQueueMetrics-dev`. The handler source is
`environments/dev/metadata/ivr_lambda/lambda_function.py`. Terraform reads the
prebuilt `lambda_function.zip` in the same directory using `filename` and
`filebase64sha256`, then uploads it directly to Lambda. This module does not
use `archive_file`. The ZIP is allowed by `.gitignore`; include it in the same
commit as the source so pipeline checkouts contain the package.

After changing the Python source, rebuild the ZIP from the repository root
before Terraform plan/apply:

```bash
python3 -m zipfile -c environments/dev/metadata/ivr_lambda/lambda_function.zip environments/dev/metadata/ivr_lambda/lambda_function.py
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

The exported contact flows currently reference `conversionOfQueueMetrics`
without the `-dev` suffix. This change creates the requested `-dev` function;
flow references, Connect Lambda association, and invocation permissions must
be configured before those flows can invoke the new function.

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
