# Survey contact flow

The dev `connect` pipeline selection creates `BTSGSD-AIAgent-SurveyFlow` in
`btsgsd-dev-us-east-1` (instance `c227a737-3e4f-4c64-8397-2d37e318801d`).
The flow definition is stored in
`environments/dev/metadata/contact-flows/BTSGSD-AIAgent-SurveyFlow.json`.

Terraform loads the supplied JSON, substitutes the managed survey table ID and
`UpdateSessionAttributes-dev` ARN, and uses the existing dependency resolver to
resolve the voicemail module and data table by their target-instance names.
The configured voicemail module name override is reused. The source JSON is
not rewritten by the resolver. Survey creation waits for the session-attributes
Lambda module, including its Connect invocation permission and association.

The [main inbound flow](main-inbound-flow.md) references this survey for transfer
and the customer remaining hook. Its ARN is also exposed through `survey_flow_arn`.

The supplied Lex bot alias, Q assistant and AI agent version, and voicemail
timestamper Lambda ARN are retained. These resources must exist and have the
required Connect associations and invocation permissions. They are not created
or verified against AWS by adding this flow. AWS validates the flow on deployment.

Commit the changes and run the pipeline from `main` with environment `dev`,
module `connect`, and action `plan`. Review the plan, then run with action
`apply` to generate and apply a fresh plan. Other Connect changes can be included.
The output `survey_flow_arn` identifies the created flow.

If the survey already exists, import it into
`aws_connect_contact_flow.survey[0]` using the Connect backend before applying;
do not create another flow with the same name. No AWS deployment or state import
is performed by these code changes.
