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
  name        = "AbbVie_Views"
  description = "Displays customer details in the agent workspace."
  type        = "CONTACT_FLOW"

  content = replace(
    var.flow_content,
    "__CUSTOMER_DETAILS_VIEW_ARN__",
    var.customer_details_view_arn
  )

  tags = merge(var.common_tags, {
    Name = "AbbVie_Views"
  })

  lifecycle {
    precondition {
      condition = (
        startswith(
          var.customer_details_view_arn,
          "${var.connect_instance_arn}/view/"
        ) &&
        can(regex(
          "/view/[0-9a-fA-F-]{36}:(\\$LATEST|[1-9][0-9]*)$",
          var.customer_details_view_arn
        ))
      )
      error_message = "Provide a version-qualified Customer Details View ARN belonging to the target Connect instance."
    }
  }
}
