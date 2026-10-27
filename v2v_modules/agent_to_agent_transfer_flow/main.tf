module "flow" {
  source = "../connect_flow_resource"

  flow = merge(var.settings, {
    name        = "BTSGSD-V2V-US-AgentToAgentTransferFlow"
    type        = "AGENT_TRANSFER"
    description = "Imported flow: BTSGSD-V2V-US-AgentToAgentTransferFlow"
    content     = replace(file("${path.module}/assets/BTSGSD-AgentToAgentTransferFlow.json"), "__CUSTOMER_QUEUE_FLOW_ARN__", var.settings.transfer_customer_queue_flow_arn)
  })
}
