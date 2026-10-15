# Customer Details view

Creates a published Amazon Connect customer-managed view using Terraform's
`aws_cloudformation_stack` resource and `AWS::Connect::View`. It uses the existing
AWS provider, with no additional provider or deployment bucket.

The Dev configuration reads its layout from
`environments/dev/metadata/views/customer_details.json`. The layout binds the
twelve inputs supplied in the requested schema. It displays the ten identity
fields, a call summary, a ServiceNow link and a Close button. The original
`Customer_Prefferred_Language` spelling is retained to match the contact flow.

Connect generates `Content.InputSchema` from the layout and component properties.
The supplied schema is a reference contract, not a writable CreateView or
CloudFormation property. AWS validates the layout and generates the authoritative
schema when publishing; a local Terraform validation cannot confirm that schema
or the rendered UI. The identity values are bound to AttributeSection item
values, the summary to TextBox content, and ScreenPopURL to an external Link URL.
Do not claim byte-for-byte equality with an exported schema before checking the
published view.

`module.customer_details_view` runs with the existing Dev `connect` pipeline
selection. Its `view_latest_arn` output supplies `module.abbvie_views` directly,
so no manual `abbvie_views_view_arn` value is required. Terraform creates the
view before creating or updating that flow. Creating the flow does not attach
it to an agent event; configure the desired Set event flow separately.

If a Customer Details view already exists in this Dev instance, reconcile its
ownership before applying: Connect view names are unique within an instance.

References:

- https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-connect-view.html
- https://docs.aws.amazon.com/connect/latest/APIReference/API_UpdateViewContent.html
- https://d3irlmavjxd3d8.cloudfront.net/?path=/docs/customer-managed-views--page
