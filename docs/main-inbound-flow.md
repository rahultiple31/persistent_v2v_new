# Dev main inbound flow

`module.main_inbound[0]` in `environments/dev/main.tf` creates `btsgsd-Main-IB-Flow` in
`btsgsd-dev-us-east-1` using the attached 65-action JSON saved at
`environments/dev/metadata/contact-flows/BTSGSD-Main-IB-Flow.json`.

The module implementation is in `modules/btsgsd-Main-IB-Flow`. Root variables
for the existing LATAM queue and phone lookup Lambda remain in `main_ib_flow.tf`.

Terraform preserves the supplied actions and transitions and substitutes the
managed US queue, customer queue flow, survey flow, agent UI flow, data tables,
and Dev Lambda ARNs. The phone lookup Lambda receives a Connect invocation
permission and association. The source export's editor metadata retains its
original resource labels; runtime references are rendered in Terraform.

These existing dependencies must be available:

- LATAM queue `BTSGSD-LATAM-MAIN-QUEUE` in the Dev instance, configurable through
  `main_ib_latam_queue_name`.
- Phone lookup Lambda `SNOW_Abbvie`, configurable through
  `main_ib_phone_lookup_function_name`.
- The supplied Q assistant, AI agent version and Lex alias, with the required
  Connect associations. These references are retained from the attachment.

The flow is new and has no existing Terraform state entry, so no migration file
or moved block is added. Its resource address is
`module.main_inbound[0].aws_connect_contact_flow.this`.

Commit the changes and run the pipeline from `main`, environment `dev`, target
module `connect`, action `plan`. Review the plan, then run action `apply` to
generate and apply a fresh plan. The `connect-queue` choice targets only the
queue and does not deploy this flow. The `main_inbound_flow_arn` output exposes
the created flow ARN. These code changes do not deploy to AWS.
