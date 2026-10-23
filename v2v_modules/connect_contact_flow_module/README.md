# VMX3 voicemail flow module

The V2V root calls this module in the existing `connect` deployment group. It uses the supplied JSON and replaces the queue ARN, beep prompt ARN, survey table ID and timestamper Lambda ARN. The module name is `VMX3_MAIN_VM_MODULE_BTSGSD-DEV-US-EAST-1` as requested.

Before planning the `connect` group, supply these values through the V2V configuration file used by the pipeline:

- `vmx3_voicemail_queue_arn`: existing voicemail queue in the V2V Connect instance.
- `vmx3_beep_prompt_arn`: existing `Beep.wav` prompt in the same instance.
- `vmx3_timestamper_lambda_arn`: existing unqualified Lambda ARN returning a string map with `vmx3_timestamp`.

The root passes its existing survey table ID. The table must contain `Language`, `voiceMailSaved` and `voiceMailModuleError` values for the caller's language. Recording storage and the VMX3 processing backend must already be configured for voicemail processing.

This module grants the target Connect instance permission to invoke the timestamper and manages the function association. Import any existing resources into these addresses before managing them here.

Creating the module does not attach it to a parent contact flow. Existing imported flow references and any dependency-name mappings must point to this module before callers can use it. The original editor metadata is retained apart from its module name; runtime references are rendered for the target environment.

Run `terraform test` from this module directory to execute mocked tests. These tests do not access AWS.
