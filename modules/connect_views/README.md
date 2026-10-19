# Customer Details view

Creates an Amazon Connect view through the AWS Cloud Control provider. Pass a
JSON layout containing `Head` and `Body` as `view_template` using `file()`.
The supplied layout must expose the `Close` action used by this module.

The dev environment loads `metadata/views/customer_details.json` and passes the
version-qualified view ARN to the `AbbVie_Views` contact flow.

AWS generates the input schema from the layout; a standalone JSON Schema cannot
be supplied as `template` or as an `input_schema` resource argument.

See [deployment and migration notes](../../docs/customer-details-view.md) before
applying to an instance that already contains this view.
