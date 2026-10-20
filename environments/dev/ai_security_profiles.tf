locals {
  dev_ai_admin_security_profile_enabled = var.dev_ai_admin_security_profile_enabled && local.deploy_connect
}

# Look up the built-in profile even when creation of a human admin user is disabled.
data "aws_connect_security_profile" "ai_admin" {
  count       = local.dev_ai_admin_security_profile_enabled ? 1 : 0
  provider    = aws.us_east_1
  instance_id = module.connect_us_east_1[0].instance_id
  name        = "Admin"
}

# The pinned AWS provider and AWS::Wisdom::AIAgent do not expose the separate
# Connect security-profile association API. Run it during apply, never planning.
resource "terraform_data" "dev_ai_admin_security_profiles" {
  count = local.dev_ai_admin_security_profile_enabled ? 1 : 0

  input = {
    python_executable = var.dev_ai_security_profile_python_executable
    script_path       = abspath("${path.module}/../../modules/connect_ai_agent/assign_admin_security_profile.py")
    config = {
      assistant_id         = local.dev_ai_assistant_id
      connect_instance_arn = module.connect_us_east_1[0].instance_arn
      admin_profile_id     = data.aws_connect_security_profile.ai_admin[0].security_profile_id
      region               = "us-east-1"
    }
  }

  triggers_replace = {
    assistant_id     = local.dev_ai_assistant_id
    admin_profile_id = data.aws_connect_security_profile.ai_admin[0].security_profile_id
    instance_arn     = module.connect_us_east_1[0].instance_arn
    python           = var.dev_ai_security_profile_python_executable
    script_hash      = filesha256("${path.module}/../../modules/connect_ai_agent/assign_admin_security_profile.py")
    survey_agent     = try(module.btsgsd_ai_survey_agent[0].deployment, null)
    support_agent    = try(module.btsgsd_support_agent[0].deployment, null)
    legacy_agent     = try(aws_cloudformation_stack.dev_ai_agent[0].outputs, null)
  }

  provisioner "local-exec" {
    command = "\"${self.input.python_executable}\" \"${self.input.script_path}\""
    environment = {
      AI_AGENT_ADMIN_PROFILE_CONFIG = jsonencode(self.input.config)
    }
  }
}
