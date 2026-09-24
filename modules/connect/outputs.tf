output "instance_id" {
  description = "Amazon Connect instance ID."
  value       = aws_connect_instance.this.id
}

output "instance_arn" {
  description = "Amazon Connect instance ARN."
  value       = aws_connect_instance.this.arn
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
