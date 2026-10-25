output "external_vm_id" {
  value = aws_connect_quick_connect.external_vms.quick_connect_id
}

output "external_vm_arn" {
  value = aws_connect_quick_connect.external_vms.arn
}

output "connect_instance_id" {
  value = data.aws_connect_instance.this.id
}