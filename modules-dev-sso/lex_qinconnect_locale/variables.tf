variable "bot_id" {
  description = "ID of the existing Lex V2 bot."
  type        = string
}

variable "bot_name" {
  description = "Expected name of the existing Lex V2 bot."
  type        = string
}

variable "locale_id" {
  description = "Lex V2 locale to configure."
  type        = string
}

variable "assistant_arn" {
  description = "Amazon Q in Connect assistant ARN for the locale's intent."
  type        = string
}
