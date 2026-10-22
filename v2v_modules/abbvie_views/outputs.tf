output "flow_id" {
  description = "Contact flow ID."
  value       = aws_connect_contact_flow.this.contact_flow_id
}

output "flow_arn" {
  description = "Contact flow ARN."
  value       = aws_connect_contact_flow.this.arn
}

output "flow_name" {
  description = "Contact flow name."
  value       = aws_connect_contact_flow.this.name
}
