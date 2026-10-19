# Lex Yes/No Lambda

The dev Connect selection deploys `BTSGSD-lex-yesNo-dev` through
`module.lex_yesno`. Terraform consumes the prebuilt
`environments/dev/metadata/BTSGSD-lex-yesNo-dev_lambda/lambda_function.zip`
using `filename` and `filebase64sha256`. There is no `archive_file` data source
in this module. The ZIP is allowed by `.gitignore` and must be included in the
same commit as its Python source.

The ZIP contains `lambda_function.py` at its root. After editing the source,
rebuild it from the repository root before planning:

```bash
python3 -m zipfile -c environments/dev/metadata/BTSGSD-lex-yesNo-dev_lambda/lambda_function.zip environments/dev/metadata/BTSGSD-lex-yesNo-dev_lambda/lambda_function.py
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
