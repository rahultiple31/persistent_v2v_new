################################################################################
# WAF Module — Input Variables
################################################################################

variable "stack_name" {
  description = "Stack name prefix applied to every resource name."
  type        = string
}

variable "alb_arn" {
  description = "ARN of the Application Load Balancer to associate the WebACL with."
  type        = string
}

variable "common_rule_set" {
  description = "true: attach AWSManagedRulesCommonRuleSet (body-size rule in count mode)."
  type        = bool
  default     = false
}
