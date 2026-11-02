# V2V deployment

Use `v2v-azure-pipeline.yml` for the active V2V environment. Select
`targetEnvironment=v2v-dev` and the required `targetModule`. Run `plan` to review,
then `apply` to deploy the new run's saved plan. See
[the V2V pipeline choice guide](docs/v2v-pipeline-choices.md) for resource groups
and prerequisites.

## Legacy environment retirement

The ten legacy proxy infrastructure modules and their callers have been
removed from the shared modules and legacy environment configurations.
The Dev NSSO environment root and its pipeline selection have also been removed.
The main `azure-pipelines.yml` no longer offers `targetModule=proxy`, and its
selector rejects that retired choice. The proxy runtime preservation helper,
module outputs, deployment settings and module migration blocks were removed
with the infrastructure code.

Removing this code does not run Terraform or delete existing AWS resources.
Existing proxy state remains in S3. Any later migration or decommissioning must
use a separately reviewed plan against that state; do not repurpose its backend
key for another deployment.

The legacy frontend stacks are also retired for new deployment.
Dev's Cognito and CloudFront module calls, migrations, and module source files
have been removed. Their existing state addresses remain supported by the
cleanup validator; the active V2V module sources remain in `v2v_modules`.
The `prepare-destroy-v2v` and `destroy-v2v-stack` choices remain
available for Dev through `azure-pipelines.yml` for the frontend cleanup workflow
explained in [README.md](README.md). Those choices do not decommission the
legacy proxy infrastructure.

Frontend compatibility settings for an explicitly configured existing proxy
remain available in Terraform; they do not provision proxy infrastructure.

## Separate V2V resource stack

The `v2v-resource-modules` infrastructure is retained. Its pipeline environment
is `v2v-resources-dev`; select an individual resource choice or `all`. It uses its
own configuration and the existing shared V2V POC state. See
[environments/v2v-resources/README.md](environments/v2v-resources/README.md).
