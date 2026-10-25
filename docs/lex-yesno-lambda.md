# Lex Yes/No Lambda

The V2V Lex bot `BTSGSD-V2V-US-yesNo` has COPPA enabled through
`module.lex_yesno_bot` in `environments/v2v/main.tf` (`child_directed = true`).
The `v2v_modules/lex_bot` module retains its alias, three locales, Lambda hooks
and invocation permissions, but omits conversation logging and its log-write
policy for COPPA bots. Privacy changes publish a replacement alias version
before retiring the previous managed version. The Lambda
`BTSGSD-V2V-US-lex-yesNo` has no COPPA setting of its own.
Deploy the bot with pipeline choice `lex_yesno_bot`; changing the Lambda alone
does not apply the bot's COPPA setting.

The dev Connect selection deploys `BTSGSD-lex-yesNo-dev` through
`module.lex_yesno`. Terraform consumes the prebuilt
`environments/dev/metadata/BTSGSD-lex-yesNo-dev_lambda-dev_lambda/lambda_function.zip`
using `filename` and `filebase64sha256`. There is no `archive_file` data source
in this module. The dev pipeline builds the ZIP from the checked-out Python
source before Terraform runs and includes it in the plan artifact. Apply
restores that exact ZIP rather than rebuilding it. The ZIP is also allowed by
`.gitignore` for local packaging.

The ZIP contains `lambda_function.py` at its root. After editing the source,
rebuild it from the repository root before planning locally:

```bash
python3 -m zipfile -c environments/dev/metadata/BTSGSD-lex-yesNo-dev_lambda-dev_lambda/lambda_function.zip environments/dev/metadata/BTSGSD-lex-yesNo-dev_lambda-dev_lambda/lambda_function.py
```

The function uses Python 3.13, x86_64, 128 MB memory, a 3-second timeout,
512 MB ephemeral storage, and 14-day log retention. The provided OpenTelemetry
layer version 32, `/opt/otel-instrument` wrapper, thresholds, and DEBUG logging
are retained. The existing `BTSGSD-lex-yesNo-role-ow5vzdof` role must trust
Lambda and already have the required telemetry permissions. The module adds
log writes scoped to `/aws/lambda/BTSGSD-lex-yesNo-dev`.

Set `lex_yesno_bot_alias_arn` to enable invocation permission for a Lex V2
alias, then configure that alias's locale Lambda code hook separately.
Outputs are `lex_yesno_lambda_name`, `lex_yesno_lambda_arn`, and
`lex_yesno_iam_role_arn`; they return null when Connect is disabled.

The supplied Python behavior is retained, including Yes/No intents, DTMF 1/2,
prompt phone substitution, and the shared retry/timeout limit. Its existing
Lex protocol issues are also retained: closing intents use `confirmationStatus`
instead of `confirmationState`, and counters become integers even though Lex
session attributes require strings. These need correcting before live use.
The local behavior tests do not validate the full Lex response contract.

Run tests from the repository root:

```bash
python3 -m unittest discover -s modules/BTSGSD-lex-yesNo-dev/tests -v
terraform -chdir=modules/BTSGSD-lex-yesNo-dev init -backend=false
terraform -chdir=modules/BTSGSD-lex-yesNo-dev test
```

The Terraform tests mock AWS and create no AWS resources.
