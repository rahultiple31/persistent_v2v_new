variable "configuration" {
  description = "Existing Lex V2 bot and locale for the customer queue intents."
  type = object({
    account_id = string
    region     = string
    bot_id     = string
    bot_name   = string
    locale_id  = string
  })
}
