# Customer Details view

The dev environment creates `module.connect_views[0]` when `enabled_modules`
includes `connect`. It uses the AWSCC provider in us-east-1 and loads
`environments/dev/metadata/views/customer_details.json` with `file()`.
Edit that JSON file to change the view layout. The layout includes the customer
fields, call summary, screen-pop link, and a `Close` button. The module's actions
match that button. AWS generates the input schema from the layout; the input
JSON Schema is not a deployable view template.

The `AbbVie_Views` contact flow uses the new module's `view_latest_arn` output.
The existing pipeline's `connect` selection includes this module; no standalone
pipeline selection has been added.

## Main inbound flow dependencies

The dev main inbound flow's `DefaultAgentUI` hook uses the managed `AbbVie_Views`
flow ARN. The Connect module also replaces the exported queue and survey ARNs
with resources looked up in the managed instance. The default lookup names are
`BTSGSD-US-MAIN-QUEUE` and `BTSGSD-AIAgent-SurveyFlow`; both resources must already
exist in that instance. If their Dev names differ, add entries keyed by these
exported names to `connect_customer_queue_dependency_names` in dev tfvars,
preserving the existing prompt and flow-module mappings.

These replacements correct identified cross-instance references. AWS still
validates the remaining exported Lambda, Lex, assistant, and other flow settings
during deployment. Generate a fresh pipeline plan after committing these fixes.

## Existing deployments

The previous configuration managed this view through the CloudFormation stack
`btsgsd-dev-Customer-Details-View` under `module.customer_details_view`.
The new AWSCC resource is a different Terraform address and resource type.
Terraform cannot move the old stack state directly to the new view resource.

Before applying to an existing deployment:

1. Check the Connect backend state and the existing CloudFormation stack.
2. If the stack owns the view, retain the view while removing its CloudFormation
   ownership (for example, use `DeletionPolicy: Retain` on that resource before
   removing it from the stack). Confirm that the view still exists and is no
   longer managed by the stack.
3. Remove the retired `module.customer_details_view` stack resource from Terraform
   state without destroying it, using a reviewed `removed` block with
   `destroy = false` or an equivalent state removal operation.
4. Import the existing unqualified view ARN into the new address, using the same
   backend and variable arguments as the Connect deployment:

   ```bash
   terraform import -var='enabled_modules=["connect"]' \
     'module.connect_views[0].awscc_connect_view.customer_details' \
     'arn:aws:connect:us-east-1:ACCOUNT_ID:instance/INSTANCE_ID/view/VIEW_ID'
   ```

5. Review the plan before applying. It should update the imported view in place
   and must not destroy the existing stack or view unexpectedly.

For a fresh instance without this view, Terraform creates it directly. No AWS
deployment, import, stack change, or remote state change is performed by adding
these files.

Resource reference:
[awscc_connect_view](https://registry.terraform.io/providers/hashicorp/awscc/latest/docs/resources/connect_view).
