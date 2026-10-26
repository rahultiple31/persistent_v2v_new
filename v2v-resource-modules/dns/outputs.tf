################################################################################
# DNS Module — Outputs
################################################################################

output "site_fqdn" {
  description = "Fully-qualified domain name of the agent portal."
  value       = aws_route53_record.site.fqdn
}

output "connect_approved_origin" {
  description = "HTTPS origin registered with the Amazon Connect instance."
  value       = var.site_https_origin
}
