variable "name_prefix" {
  description = "Name prefix for CloudFront resources."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,48}$", var.name_prefix))
    error_message = "name_prefix must be 1-48 characters and contain only letters, numbers, hyphens, or underscores."
  }
}

variable "app_name" {
  description = "Application name used in CloudFront comments."
  type        = string
}

variable "v2v_root_prefix" {
  description = "S3 object prefix that CloudFront serves as the V2V application root."
  type        = string

  validation {
    condition     = var.v2v_root_prefix == "" || (!startswith(var.v2v_root_prefix, "/") && length(regexall("//", var.v2v_root_prefix)) == 0)
    error_message = "v2v_root_prefix must be empty or a relative S3 prefix without a leading slash or double slashes."
  }
}

variable "v2v_bucket_regional_domain_name" {
  description = "Regional domain name for the V2V application bucket."
  type        = string
}

variable "v2v_log_bucket_domain_name" {
  description = "Domain name for the CloudFront log bucket."
  type        = string
}

variable "polly_region" {
  description = "AWS Region used by Amazon Polly."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$", var.polly_region))
    error_message = "polly_region must be a valid AWS region name, for example us-east-1."
  }
}

variable "polly_proxy_enabled" {
  description = "Whether CloudFront should proxy browser requests to Amazon Polly."
  type        = bool
}

variable "translate_region" {
  description = "AWS Region used by Amazon Translate."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$", var.translate_region))
    error_message = "translate_region must be a valid AWS region name, for example us-east-1."
  }
}

variable "translate_proxy_enabled" {
  description = "Whether CloudFront should proxy browser requests to Amazon Translate."
  type        = bool
}

variable "common_tags" {
  description = "Common tags applied to supported resources."
  type        = map(string)
  default     = {}
}
