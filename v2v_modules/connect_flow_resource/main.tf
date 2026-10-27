data "aws_region" "current" {}

data "external" "dependencies" {
  count = var.flow.resolve_dependencies ? 1 : 0

  program = [var.flow.python_executable, "${path.module}/scripts/resolve_customer_queue_dependencies.py"]
  query = {
    region         = data.aws_region.current.region
    instance_id    = split("/", var.flow.instance_arn)[1]
    instance_arn   = var.flow.instance_arn
    content        = var.flow.content
    name_overrides = jsonencode(var.flow.dependency_names)
  }
}

resource "aws_connect_contact_flow" "this" {
  instance_id = split("/", var.flow.instance_arn)[1]
  name        = var.flow.name
  type        = var.flow.type
  description = var.flow.description
  content     = var.flow.resolve_dependencies ? data.external.dependencies[0].result.content : var.flow.content
  tags        = merge(var.flow.tags, { Name = var.flow.name })

  lifecycle {
    precondition {
      condition     = var.flow.expected_instance_arn == null ? true : var.flow.instance_arn == var.flow.expected_instance_arn
      error_message = "The flow must belong to the selected V2V Connect instance."
    }
    precondition {
      condition     = can(jsondecode(var.flow.content).Actions[0].Type) && can(jsondecode(var.flow.content).StartAction)
      error_message = "Supply a complete contact flow JSON export containing StartAction and Actions."
    }
  }
}
