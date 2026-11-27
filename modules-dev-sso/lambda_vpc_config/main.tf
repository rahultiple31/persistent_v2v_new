# Updates the existing function's $LATEST configuration on first apply
# and when the requested settings change.
# Assumes the existing Lambda execution role has VPC ENI permissions.
resource "terraform_data" "vpc_config" {
  triggers_replace = {
    function_arn = var.function_arn
    region       = split(":", var.function_arn)[3]
    vpc_config = jsonencode({
      SubnetIds               = sort(tolist(var.subnet_ids))
      SecurityGroupIds        = sort(tolist(var.security_group_ids))
      Ipv6AllowedForDualStack = var.ipv6_allowed_for_dual_stack
    })
  }

  provisioner "local-exec" {
    interpreter = [
      "aws", "lambda", "update-function-configuration",
      "--function-name", self.triggers_replace.function_arn,
      "--region", self.triggers_replace.region,
      "--query", "LastUpdateStatus",
      "--output", "text",
      "--no-cli-pager",
      "--vpc-config",
    ]
    command = self.triggers_replace.vpc_config
  }

  provisioner "local-exec" {
    interpreter = [
      "aws", "lambda", "wait", "function-updated",
      "--region", self.triggers_replace.region,
      "--no-cli-pager",
      "--function-name",
    ]
    command = self.triggers_replace.function_arn
  }
}
