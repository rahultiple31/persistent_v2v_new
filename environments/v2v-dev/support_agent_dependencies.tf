# V2V AI wiring shared by the states that call or are called by the SupportAgent.
# Everything resolves to the V2V instance, the V2V assistant and the V2V IT
# Support bot; nothing points at the dev instance any more.

locals {
  # The IT Support bot (module.lex_bot) and the alias its configure script creates.
  it_support_bot = {
    name       = "BTSGSD-V2V-US-IT-Support_Agent"
    alias_name = "btsgsd-alias-dev-sso"
  }

  # States outside connect that reference the V2V assistant and instance:
  # the IT Support bot's Q in Connect intent, and the Lambdas the agent invokes.
  v2v_ai_consumer_state = anytrue([
    for group in ["lex_bot", "btsgsd-v2v-us-snow", "btsgsd-v2v-us-servicenow_interaction"] :
    contains(local.enabled_module_set, group)
  ])
}

# The V2V assistant is created by aws_cloudformation_stack.dev_ai_domain in the
# connect state; other states read the same stack.
data "aws_cloudformation_stack" "v2v_ai_domain" {
  count    = local.v2v_ai_consumer_state ? 1 : 0
  provider = aws.us_east_1
  name     = "${local.dev_ai_name_prefix}-ai-domain"
}

locals {
  # Used outside connect only; in connect the Main IB flow takes the assistant
  # from module.btsgsd_support_agent.
  v2v_ai_assistant_arn = try(data.aws_cloudformation_stack.v2v_ai_domain[0].outputs["AssistantArn"], null)
  # Every AI agent (and version) on the V2V assistant; the SupportAgent ID
  # changes whenever the agent is recreated.
  v2v_ai_agent_source_arn = (
    local.v2v_ai_assistant_arn == null ? null :
    "${replace(local.v2v_ai_assistant_arn, ":assistant/", ":ai-agent/")}/*"
  )
}

# The IT Support alias is created by v2v_modules/lex_bot/configure_it_support.py,
# outside Terraform state, so the Main IB flow looks it up by name (read-only).
data "external" "it_support_bot_alias" {
  count   = local.deploy_connect && var.main_ib_it_support_bot_alias_arn == null ? 1 : 0
  program = [var.connect_flow_python_executable, "${path.module}/../../scripts/resolve-lex-bot-alias.py"]
  query = {
    bot_name   = local.it_support_bot.name
    alias_name = local.it_support_bot.alias_name
    account_id = split(":", local.connect_target_instance_arn)[4]
    region     = "us-east-1"
  }
}

locals {
  main_ib_it_support_bot_alias_arn = var.main_ib_it_support_bot_alias_arn != null ? var.main_ib_it_support_bot_alias_arn : try(
    data.external.it_support_bot_alias[0].result.alias_arn,
    null
  )
}

output "v2v_ai_wiring" {
  description = "V2V assistant, AgentCore invoke scope and IT Support alias resolved for this state (null where unused)."
  value = {
    assistant_arn            = local.v2v_ai_assistant_arn
    ai_agent_source_arn      = local.v2v_ai_agent_source_arn
    connect_instance_arn     = local.connect_target_instance_arn
    it_support_bot_alias_arn = local.main_ib_it_support_bot_alias_arn
  }
}
