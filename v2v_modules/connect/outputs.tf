output "instance_id" {
  description = "Amazon Connect instance ID."
  value       = data.aws_connect_instance.this.id
}

output "instance_arn" {
  description = "Amazon Connect instance ARN."
  value       = data.aws_connect_instance.this.arn
}

output "queue_id" {
  description = "Primary queue ID."
  value       = aws_connect_queue.primary.queue_id
}

output "routing_profile_id" {
  description = "Primary routing profile ID."
  value       = aws_connect_routing_profile.primary.routing_profile_id
}

output "admin_user_id" {
  description = "Amazon Connect administrator user ID."
  value       = try(aws_connect_user.admin[0].user_id, null)
}

output "customer_queue_flow_arn" {
  description = "Imported customer queue flow ARN for inbound flow hooks."
  value       = try(aws_connect_contact_flow.imported["customer_queue"].arn, null)
}

output "outbound_whisper_flow_id" {
  description = "Outbound whisper flow ID, used as the outbound flow of migrated queues."
  value       = try(aws_connect_contact_flow.outbound_whisper[0].contact_flow_id, null)
}

output "agent_transfer_flow_id" {
  description = "Agent-to-agent transfer flow ID."
  value       = try(aws_connect_contact_flow.agent_to_agent_transfer[0].contact_flow_id, null)
}
