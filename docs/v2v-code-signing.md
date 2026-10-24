# V2V Lambda code signing

Run `v2v-azure-pipeline.yml` from `main` with `targetModule=code-signing`
and `terraformAction=plan`. This deploys the complete signing group.
`signing_profile` targets just the profile; `code_signing_config` targets
the configuration and its profile dependency. All three choices use:

```text
terraform-state/v2v/us-east-1/code-signing/terraform.tfstate
```

The group creates an AWS Signer profile and a Lambda code-signing
configuration that trusts the profile's version ARN. Both modules use the
`us-east-1` provider. Other deployment groups do not create these resources.
After reviewing the plan, select `terraformAction=apply` to deploy the group.

The existing profile name `BTFSD_V2V_US` is preserved. Set
`signing_profile_name` before the first deployment if a different name is
required. A profile name change replaces the profile; AWS does not allow
reusing a canceled signing profile name, as documented in the
[Terraform AWS Signer resource](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/signer_signing_profile).
Import an existing profile into this
state instead of attempting to create the same profile again.

`enable_signing_profile` and `enable_code_signing_config` default to `true`.
For a scoped profile-only deployment, select `signing_profile` without
changing feature flags or removing the configuration from its state.
Enabling the configuration while disabling the profile fails validation
with a dependency error. To disable both, set both flags to `false`.

If either module was already applied using another backend key, migrate its
existing Terraform ownership into the code-signing state before applying
the updated configuration. The pipeline rejects changes to these resources
from another deployment group and rejects unrelated changes from the
code-signing group. It does not migrate or modify remote state automatically.

The configuration retains the existing `Warn` policy. It does not sign
deployment ZIPs. Actual code-signing enforcement also requires signing jobs,
deployment of signed ZIPs, and an `Enforce` policy.

## Associate the configuration with all V2V Lambdas

After deploying the code-signing group, copy its
`v2v_code_signing_config_arn` output into `lambda_code_signing_config_arn`
in `environments/v2v/terraform.tfvars`. Use the configuration ARN rather
than the description `BTFSD-V2V-US`.

```hcl
lambda_code_signing_config_arn = "REPLACE_WITH_ACTUAL_CONFIGURATION_ARN"
```

All 12 V2V Lambda module calls pass that value to their existing
`aws_lambda_function` resources through `code_signing_config_arn`.
Deploy each Lambda's individual pipeline choice or owning group to apply the association; running
only the code-signing group does not update functions in other states.

The environment requires a non-null configuration ARN for the Connect,
generic Lambda, three CTR Lambda, SNOW, ServiceNow Interaction, and Nextthink
Handoff groups. Other deployment groups, including the initial code-signing
deployment, do not require it. The ARN is validated for account
`518902362956` and region `us-east-1`. Reusable child modules retain a null
default for callers outside this environment.
