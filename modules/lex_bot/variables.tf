variable "bot_name" {
  description = "Lex V2 bot name."
  type        = string
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
