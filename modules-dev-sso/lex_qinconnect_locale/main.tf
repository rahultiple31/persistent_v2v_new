resource "terraform_data" "locale" {
  triggers_replace = {
    bot_id        = var.bot_id
    bot_name      = var.bot_name
    locale_id     = var.locale_id
    assistant_arn = var.assistant_arn
    script_hash   = filesha256("${path.module}/configure_lex_qinconnect_locale.py")
  }

  provisioner "local-exec" {
    interpreter = ["python"]
    command     = abspath("${path.module}/configure_lex_qinconnect_locale.py")

    environment = {
      LEX_BOT_ID        = self.triggers_replace.bot_id
      LEX_BOT_NAME      = self.triggers_replace.bot_name
      LEX_LOCALE_ID     = self.triggers_replace.locale_id
      LEX_ASSISTANT_ARN = self.triggers_replace.assistant_arn
      LEX_AWS_REGION    = split(":", self.triggers_replace.assistant_arn)[3]
    }
  }
}
