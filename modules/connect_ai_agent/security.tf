resource "aws_connect_security_profile" "retrieval" {
  instance_id = split("/", var.connect_instance_arn)[1]
  name        = "${var.agent_name}-retrieval"
  description = "Knowledge-base retrieval permission for ${var.agent_name}."
  permissions = [
    "Wisdom.View"
  ]
  tags = local.tags
}

# The pinned AWS provider does not expose AI-agent security profile associations.
# Associate the profile after CloudFormation publishes the agent and its version.
resource "terraform_data" "retrieval_security_profile" {
  input = {
    instance_id         = aws_connect_security_profile.retrieval.instance_id
    security_profile_id = aws_connect_security_profile.retrieval.security_profile_id
    agent_arns = [
      aws_cloudformation_stack.agent.outputs["AgentArn"],
      aws_cloudformation_stack.agent.outputs["AgentVersionArn"]
    ]
    region            = data.aws_region.current.name
    account_id        = data.aws_caller_identity.current.account_id
    aws_profile       = var.aws_profile
    python_executable = var.python_executable
    script_path       = abspath("${path.module}/manage_security_profiles.py")
  }

  triggers_replace = {
    security_profile_id = aws_connect_security_profile.retrieval.security_profile_id
    agent_arn           = aws_cloudformation_stack.agent.outputs["AgentArn"]
    agent_version_arn   = aws_cloudformation_stack.agent.outputs["AgentVersionArn"]
    script_hash         = filesha256("${path.module}/manage_security_profiles.py")
    aws_profile         = var.aws_profile
  }

  provisioner "local-exec" {
    interpreter = [self.input.python_executable, "-c"]
    command     = "import os, runpy; runpy.run_path(os.environ['AI_SECURITY_SCRIPT'], run_name='__main__')"
    environment = {
      AI_SECURITY_SCRIPT = self.input.script_path
      AI_SECURITY_QUERY  = jsonencode(self.input)
      AI_SECURITY_ACTION = "associate"
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = [self.input.python_executable, "-c"]
    command     = "import os, runpy; runpy.run_path(os.environ['AI_SECURITY_SCRIPT'], run_name='__main__')"
    environment = {
      AI_SECURITY_SCRIPT = self.input.script_path
      AI_SECURITY_QUERY  = jsonencode(self.input)
      AI_SECURITY_ACTION = "disassociate"
    }
  }
}
