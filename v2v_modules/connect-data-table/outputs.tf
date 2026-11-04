output "deployment" {
  value = {
    name = local.config.name
    arn  = aws_cloudformation_stack.this.outputs["DataTableArn"]
    id = element(
      reverse(split("/", aws_cloudformation_stack.this.outputs["DataTableArn"])),
      0
    )
  }
}

output "template_json" {
  value = local.template_json
}

output "rows" {
  value = local.rows
}

output "template_url" {
  value = aws_cloudformation_stack.this.template_url
}
