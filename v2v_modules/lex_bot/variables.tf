variable "bot_name" {
  description = "Lex V2 bot name."
  type        = string
}

variable "child_directed" {
  description = "Whether the bot is subject to COPPA."
  type        = bool
  default     = false
}

variable "locale_ids" {
  description = "Languages added to the blank bot."
  type        = set(string)

  default = [
    "en_US",  # English (US)
    "hi_IN",  # Hindi (IN)
    "pt_BR",  # Portuguese (BR)
    "es_419", # Spanish (LATAM)
  ]
}

variable "enable_english_yesno_intents" {
  description = "Add English yes/no survey intents to this bot."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_english_yesno_intents || contains(var.locale_ids, "en_US")
    error_message = "English yes/no intents require the en_US locale."
  }
}

variable "enable_portuguese_yesno_intents" {
  description = "Add Portuguese (BR) yes/no survey intents to this bot."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_portuguese_yesno_intents || contains(var.locale_ids, "pt_BR")
    error_message = "Portuguese yes/no intents require the pt_BR locale."
  }
}

variable "enable_spanish_yesno_intents" {
  description = "Add Spanish (LATAM) yes/no survey intents to this bot."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_spanish_yesno_intents || contains(var.locale_ids, "es_419")
    error_message = "Spanish yes/no intents require the es_419 locale."
  }
}
