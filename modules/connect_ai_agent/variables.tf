variable "assistant_id" {
  description = "Existing assistant UUID associated with the Connect instance."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$", var.assistant_id))
    error_message = "assistant_id must be an assistant UUID."
  }
}

variable "connect_instance_arn" {
  description = "ARN of the existing Connect instance; this module does not create an instance."
  type        = string
}

variable "template_bucket_name" {
  description = "Existing private S3 bucket in the provider region for CloudFormation templates."
  type        = string
  nullable    = false
}

variable "prompt_yaml_file" {
  description = "YAML file containing a complete system prompt (with optional messages) or prompt instructions appended to the source system; may include description and test_question metadata."
  type        = string
  nullable    = false

  validation {
    condition     = fileexists(var.prompt_yaml_file)
    error_message = "Prompt file does not exist: ${var.prompt_yaml_file}. Commit the file to the pipeline source branch and verify the path and filename case."
  }

  validation {
    condition     = fileexists(var.prompt_yaml_file) ? try(length(trimspace(try(yamldecode(file(var.prompt_yaml_file)).system, yamldecode(file(var.prompt_yaml_file)).prompt))) > 0, false) : true
    error_message = "Prompt file ${var.prompt_yaml_file} must contain a nonempty top-level system or prompt string. Use system: | or prompt: | followed by indented instructions."
  }
}

variable "agent_name" {
  type = string
}

variable "prompt_name" {
  type = string
}

variable "source_agent_name" {
  description = "System orchestration agent whose voice template, tools, locale, and guardrail are copied."
  type        = string
  default     = "SelfServiceOrchestratorVoice"
}

variable "prompt_model_id" {
  description = "Active Connect orchestration model using global cross-region inference."
  type        = string
  default     = "global.anthropic.claude-sonnet-5"
}

variable "stack_name" {
  type = string
}

variable "python_executable" {
  description = "Python 3 executable on the runner; use python for Windows or python3 for Linux."
  type        = string
  default     = "python3"
}

variable "aws_profile" {
  description = "Optional CLI profile matching the provider credentials; leave empty for pipeline OIDC."
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
