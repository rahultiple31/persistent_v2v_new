output "instance_id" {
  value = local.instance_id
}

output "hours_of_operation_id" {
  value = aws_connect_hours_of_operation.hours.hours_of_operation_id
}

output "queue_id" {
  value = aws_connect_queue.queue.queue_id
}

output "queue_arn" {
  value = aws_connect_queue.queue.arn
}

output "quick_connect_ids" {
  value = { for name, qc in aws_connect_quick_connect.help_desk : name => qc.quick_connect_id }
}
