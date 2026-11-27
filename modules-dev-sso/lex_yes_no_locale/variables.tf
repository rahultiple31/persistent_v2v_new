variable "configuration" {
  description = "Existing Lex V2 bot, locale, and sample utterances to configure."
  type = object({
    account_id = string
    region     = string
    bot_id     = string
    bot_name   = string
    locale_id  = string
    intents    = map(set(string))
  })
}
