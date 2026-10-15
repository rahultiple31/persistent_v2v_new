output "bot_id" {
  value = aws_lexv2models_bot.this.id
}

output "bot_name" {
  value = aws_lexv2models_bot.this.name
}

output "locale_ids" {
  value = keys(aws_lexv2models_bot_locale.this)
}
