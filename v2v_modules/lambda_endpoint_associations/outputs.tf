output "endpoint_ids" {
  value = {
    for service, endpoint in data.aws_vpc_endpoint.this :
    service => endpoint.id
  }
}

output "endpoint_security_group_id" {
  value = data.aws_security_group.endpoint.id
}
