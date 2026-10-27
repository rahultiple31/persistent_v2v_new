output "instance_id" {
  description = "Amazon Connect instance ID these resources attach to."
  value       = local.instance_id
}

output "queue_ids" {
  description = "Created queue IDs keyed by queue name."
  value = {
    (aws_connect_queue.latam_main.name) = aws_connect_queue.latam_main.queue_id
    (aws_connect_queue.latam_out.name)  = aws_connect_queue.latam_out.queue_id
    (aws_connect_queue.us_main.name)    = aws_connect_queue.us_main.queue_id
    (aws_connect_queue.us_out.name)     = aws_connect_queue.us_out.queue_id
    (aws_connect_queue.us_vm.name)      = aws_connect_queue.us_vm.queue_id
  }
}

output "hours_of_operation_id" {
  description = "V2V hours of operation ID used by the queues."
  value       = aws_connect_hours_of_operation.v2v.hours_of_operation_id
}

output "routing_profile_ids" {
  description = "Routing profile IDs keyed by routing profile key (basic, us_agent, latam_agent, us_latam_vm_blended)."
  value       = local.routing_profile_ids
}

output "agent_status_arns" {
  description = "Created custom agent status ARNs keyed by name."
  value = {
    for status in [
      awscc_connect_agent_status.after_call_work,
      awscc_connect_agent_status.backlog,
      awscc_connect_agent_status.bio_break,
      awscc_connect_agent_status.break,
      awscc_connect_agent_status.call_outbound,
      awscc_connect_agent_status.chat,
      awscc_connect_agent_status.consultation,
      awscc_connect_agent_status.email,
      awscc_connect_agent_status.escalations,
      awscc_connect_agent_status.external_vms,
      awscc_connect_agent_status.follow_ups,
      awscc_connect_agent_status.internal_vms,
      awscc_connect_agent_status.lunch,
      awscc_connect_agent_status.remote_session,
      awscc_connect_agent_status.training,
    ] : status.name => status.agent_status_arn
  }
}

output "security_profile_ids" {
  description = "Security profile IDs keyed by name (custom profiles created here, default profiles resolved as data)."
  value       = local.security_profile_ids
}

output "prompt_arns" {
  description = "Prompt ARNs keyed by name: default prompts plus MOH_30SEC once its S3 URI is supplied."
  value = merge(
    { for name, p in data.aws_connect_prompt.default : name => p.arn },
    { for p in awscc_connect_prompt.moh_30sec : p.name => p.prompt_arn }
  )
}

output "quick_connect_ids" {
  description = "Created user quick connect IDs keyed by name."
  value = {
    (aws_connect_quick_connect.mahendra_kumar.name)    = aws_connect_quick_connect.mahendra_kumar.quick_connect_id
    (aws_connect_quick_connect.smita_kulkarni.name)    = aws_connect_quick_connect.smita_kulkarni.quick_connect_id
    (aws_connect_quick_connect.govind_khandelwal.name) = aws_connect_quick_connect.govind_khandelwal.quick_connect_id
  }
}

output "user_ids" {
  description = "Created user IDs keyed by username (empty when create_users is false)."
  value       = { for name, u in aws_connect_user.this : name => u.user_id }
}
