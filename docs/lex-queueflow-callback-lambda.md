# Lex queue callback Lambda

The dev Connect selection deploys `BTSGSD-lex-QueueFlow-Callback-dev` through
`module.lex_queueflow_callback`. Its handler is
`environments/dev/metadata/BTSGSD-lex-QueueFlow-Callback-dev_lambda/lambda_function.py`.
Terraform deploys the prebuilt `lambda_function.zip` in the same directory
using `filename` and `filebase64sha256`. This module does not use
`archive_file`. The ZIP is allowed by `.gitignore`; include it in the same
commit as its source so the pipeline checkout contains the package.

Rebuild the ZIP from the repository root whenever the handler changes, before
running Terraform plan/apply:

```bash
python3 -m zipfile -c environments/dev/metadata/BTSGSD-lex-QueueFlow-Callback-dev_lambda/lambda_function.zip environments/dev/metadata/BTSGSD-lex-QueueFlow-Callback-dev_lambda/lambda_function.py
```

The ZIP must contain only the current `lambda_function.py` at its root.

Configuration: Python 3.13, x86_64, 128 MB memory, a 3-second timeout,
512 MB ephemeral storage, and 14-day retention for
`/aws/lambda/BTSGSD-lex-QueueFlow-Callback-dev`.
The supplied OpenTelemetry layer version 32 and `/opt/otel-instrument` wrapper
are retained, with `LOWER_THRESHOLD=0.4`, `UPPER_THRESHOLD=0.7`, and
`LOG_LEVEL=DEBUG`.

The existing `BTSGSD-lex-QueueFlow-Callback-role-i0v0kqis` role must trust
`lambda.amazonaws.com` and already have the telemetry permissions required by
the selected layer. This module adds log-stream creation and log-write
permissions scoped to its configured log group. The layer must be accessible
to the deployment account in us-east-1.

Set `lex_queueflow_callback_bot_alias_arn` to grant the supplied Lex V2 alias
permission to invoke this function. The default null creates no invocation
permission. Configure that alias's locale Lambda code hook separately; the
existing `lex_bot` module creates a different blank bot and supplies no alias.

If the function or log group already exists outside this Terraform state,
import it before applying.

The handler preserves the supplied voicemail, virtualQueue, repeat, retry,
timeout, and combined three-attempt behavior. This packaging change leaves the
current Python source unchanged. That source currently uses
`confirmationStatus` instead of `confirmationState`, returns integer counters
in session attributes, and removes an opening SSML wrapper twice rather than
removing its closing wrapper. The existing handler contract tests detect these
issues; packaging and Terraform checks do not establish Lex runtime correctness.
The expected response types are documented in:
[Lex Lambda responses](https://docs.aws.amazon.com/lexv2/latest/dg/lambda-response-format.html)
and [Lex session attributes](https://docs.aws.amazon.com/lexv2/latest/APIReference/API_runtime_SessionState.html).
The existing downstream `repeat_confimation` value is preserved.
Threshold variables remain available as in the supplied handler; its intent
routing does not apply confidence threshold logic.

Dev outputs are `lex_queueflow_callback_lambda_name`,
`lex_queueflow_callback_lambda_arn`, and `lex_queueflow_callback_iam_role_arn`,
returning null when Connect is disabled.

Run tests from the repository root:

```bash
python3 -m unittest discover -s modules/BTSGSD-lex-QueueFlow-Callback-dev/tests -v
terraform -chdir=modules/BTSGSD-lex-QueueFlow-Callback-dev init -backend=false
terraform -chdir=modules/BTSGSD-lex-QueueFlow-Callback-dev test
```

Terraform tests mock AWS and read the prebuilt ZIP; they create no AWS resources.
