################################################################################
# DNS Module — Input Variables
################################################################################

variable "stack_name" {
  description = "Stack name prefix applied to every resource name."
  type        = string
}

variable "hostname" {
  description = "Fully-qualified domain name for the agent portal (e.g. v2v.example.com)."
  type        = string
}

variable "hosted_zone_id" {
  description = "Route 53 hosted-zone ID that contains the hostname."
  type        = string
}

variable "alb_dns_name" {
  description = "Internal DNS name of the Application Load Balancer (alias target)."
  type        = string
}

variable "alb_zone_id" {
  description = "Hosted-zone ID of the ALB (required for Route 53 alias records)."
  type        = string
}

variable "connect_instance_arn" {
  description = "ARN of the Amazon Connect instance to add the site as an approved origin."
  type        = string
}

variable "site_https_origin" {
  description = "https:// origin registered with Connect (e.g. https://v2v.example.com)."
  type        = string
}
