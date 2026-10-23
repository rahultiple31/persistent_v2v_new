output "bot_id" {
  value = aws_lexv2models_bot.this.id
}

output "execution_role_name" {
  value = aws_iam_role.lex.name
}

output "bot_alias_id" {
  value = try(awscc_lex_bot_alias.this[0].bot_alias_id, null)
}

output "bot_alias_arn" {
  value = try(awscc_lex_bot_alias.this[0].arn, null)
}

output "alias_bot_version" {
  value = try(aws_lexv2models_bot_version.alias_text_logs[0].bot_version, null)
}

output "bot_name" {
  value = aws_lexv2models_bot.this.name
}

output "locale_ids" {
  value = keys(aws_lexv2models_bot_locale.this)
}

output "published_bot_version" {
  description = "AWS-assigned version number; 1 on the first publication."
  value       = try(aws_lexv2models_bot_version.yesno_version_1[0].bot_version, null)
}
