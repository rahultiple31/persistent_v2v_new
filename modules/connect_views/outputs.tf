output "view_id" {
  description = "Customer Details view ID."
  value       = aws_cloudformation_stack.this.outputs["ViewId"]
}

output "view_arn" {
  description = "Unqualified Customer Details view ARN."
  value       = aws_cloudformation_stack.this.outputs["ViewArn"]
}

output "view_latest_arn" {
  description = "Published Customer Details view ARN for the ShowView action."
  value       = "${aws_cloudformation_stack.this.outputs["ViewArn"]}:$LATEST"
}

output "view_name" {
  description = "Customer Details view display name."
  value       = var.view_name
}
