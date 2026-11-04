terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100.0, < 7.0.0"
    }
  }
}

resource "aws_connect_contact_flow" "this" {
  instance_id = split("/", var.connect_instance_arn)[1]
  name        = "BTSGSD-V2V-US-Views"
  description = "Displays customer details in the agent workspace."
  type        = "CONTACT_FLOW"

  content = replace(
    replace(
      file("${path.module}/assets/abbvie_views.json"),
      "__CUSTOMER_DETAILS_VIEW_ARN__",
      var.customer_details_view_arn
    ),
    "__CUSTOMER_INFORMATION_VIEW_ARN__",
    var.customer_information_view_arn
  )

  tags = merge(var.common_tags, {
    Name = "BTSGSD-V2V-US-Views"
  })

  lifecycle {
    precondition {
      condition = alltrue([
        for view_arn in [
          var.customer_details_view_arn,
          var.customer_information_view_arn
        ] : (
          startswith(
            view_arn,
            "${var.connect_instance_arn}/view/"
          ) &&
          can(regex(
            "/view/[0-9a-fA-F-]{36}:(\\$LATEST|[1-9][0-9]*)$",
            view_arn
          ))
        )
      ])
      error_message = "Provide version-qualified Customer Details and Customer Information View ARNs belonging to the target Connect instance."
    }
  }
}
