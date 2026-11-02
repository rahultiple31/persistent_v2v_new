locals {
  endpoint_names = {
    secretsmanager = "BTSGSD-US-LAMBDA-endpoint-secretsmanager"
    transcribe     = "BTSGSD-US-LAMBDA-endpoint-transcribe"
    connect        = "BTSGSD-US-LAMBDA-endpoint-connect"
    wisdom         = "BTSGSD-US-LAMBDA-endpoint-wisdom"
    lambda         = "BTSGSD-US-LAMBDA-endpoint-lambda"
  }
}

data "aws_security_group" "endpoint" {
  name   = var.endpoint_security_group_name
  vpc_id = var.vpc_id
}

# Read existing interface endpoints by their exact Name tags.
data "aws_vpc_endpoint" "this" {
  for_each = local.endpoint_names

  vpc_id = var.vpc_id

  filter {
    name   = "tag:Name"
    values = [each.value]
  }

  filter {
    name   = "vpc-endpoint-type"
    values = ["Interface"]
  }
}

# Creates five individual association instances while retaining existing groups.
# The existing endpoints are data sources and require no import.
resource "aws_vpc_endpoint_security_group_association" "endpoint" {
  for_each = local.endpoint_names

  vpc_endpoint_id             = data.aws_vpc_endpoint.this[each.key].id
  security_group_id           = data.aws_security_group.endpoint.id
  replace_default_association = false
}
