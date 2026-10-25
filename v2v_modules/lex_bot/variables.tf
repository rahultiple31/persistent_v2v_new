variable "bot_name" {
  description = "Lex V2 bot name."
  type        = string
}

variable "it_support_configuration" {
  description = "Optional multilingual IT Support Q in Connect configuration."
  type = object({
    assistant_arn        = string
    connect_instance_arn = string
    alias_name           = string
  })
  default = null

  validation {
    condition = var.it_support_configuration == null ? true : (
      var.child_directed &&
      var.alias_configuration == null &&
      !anytrue([
        var.publish_yesno_version,
        var.publish_customer_queue_version,
        var.enable_english_yesno_intents,
        var.enable_portuguese_yesno_intents,
        var.enable_spanish_yesno_intents,
        var.enable_english_customer_queue_intents,
        var.enable_portuguese_customer_queue_intents,
        var.enable_spanish_customer_queue_intents,
      ]) &&
      alltrue([
        for locale in ["en_US", "hi_IN", "pt_BR", "es_419"] :
        contains(var.locale_ids, locale)
      ])
    )
    error_message = "IT Support configuration requires COPPA=true, all four locales, and the other intent/alias modes disabled."
  }
}

variable "alias_configuration" {
  description = "Optional alias, Lambda and Connect policy configuration. Text logging is disabled when child_directed is true."
  type = object({
    name                 = string
    lambda_function_arn  = string
    connect_instance_arn = string
    text_log_group_arn   = string
  })
  default = null

  validation {
    condition = var.alias_configuration == null ? true : (
      var.publish_yesno_version || var.publish_customer_queue_version
    )
    error_message = "The alias requires bot-version publishing enabled."
  }

  validation {
    condition = var.alias_configuration == null ? true : can(regex(
      "^arn:aws:lambda:[a-z0-9-]+:[0-9]{12}:function:[A-Za-z0-9_-]+$",
      var.alias_configuration.lambda_function_arn
    ))
    error_message = "Use an unqualified Lambda ARN to invoke $LATEST."
  }

  validation {
    condition = var.alias_configuration == null ? true : can(regex(
      "^arn:aws:connect:[a-z0-9-]+:[0-9]{12}:instance/[0-9a-f-]+$",
      var.alias_configuration.connect_instance_arn
    ))
    error_message = "Provide a valid Amazon Connect instance ARN."
  }
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

variable "enable_english_customer_queue_intents" {
  description = "Add English repeat, virtualQueue, voicemail and fallback configuration."
  type        = bool
  default     = false

  validation {
    condition = !var.enable_english_customer_queue_intents || (
      contains(var.locale_ids, "en_US") &&
      !var.enable_english_yesno_intents
    )
    error_message = "Customer queue intents require en_US and cannot share that locale with the yes/no intents because both define repeat."
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

variable "enable_portuguese_customer_queue_intents" {
  description = "Add Portuguese customer queue intents and fallback configuration."
  type        = bool
  default     = false

  validation {
    condition = !var.enable_portuguese_customer_queue_intents || (
      contains(var.locale_ids, "pt_BR") &&
      !var.enable_portuguese_yesno_intents
    )
    error_message = "Portuguese customer queue intents require pt_BR and cannot share that locale with the Portuguese yes/no intents because both define repeat."
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

variable "enable_spanish_customer_queue_intents" {
  description = "Add Spanish LATAM customer queue intents and fallback configuration."
  type        = bool
  default     = false

  validation {
    condition = !var.enable_spanish_customer_queue_intents || (
      contains(var.locale_ids, "es_419") &&
      !var.enable_spanish_yesno_intents
    )
    error_message = "Spanish customer queue intents require es_419 and cannot share that locale with the Spanish yes/no intents because both define repeat."
  }
}

variable "publish_yesno_version" {
  description = "Publish a version containing the three yes/no survey locales."
  type        = bool
  default     = false

  validation {
    condition = !var.publish_yesno_version || (
      var.enable_english_yesno_intents &&
      var.enable_portuguese_yesno_intents &&
      var.enable_spanish_yesno_intents &&
      alltrue([
        for locale in ["en_US", "pt_BR", "es_419"] :
        contains(var.locale_ids, locale)
      ])
    )

    error_message = "Publishing the survey version requires all three locales and their intent flags."
  }
}

variable "publish_customer_queue_version" {
  description = "Build all three customer queue locales before publishing the alias version."
  type        = bool
  default     = false

  validation {
    condition = !var.publish_customer_queue_version || (
      !var.publish_yesno_version &&
      var.enable_english_customer_queue_intents &&
      var.enable_portuguese_customer_queue_intents &&
      var.enable_spanish_customer_queue_intents &&
      alltrue([
        for locale in ["en_US", "pt_BR", "es_419"] :
        contains(var.locale_ids, locale)
      ])
    )
    error_message = "Customer queue publication requires all three customer queue intent flags and locales, with yes/no publication disabled."
  }
}
