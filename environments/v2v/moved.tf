# Preserve resource ownership when renaming V2V Lambda modules.
moved {
  from = module.lambda-servicenow-interaction
  to   = module.BTSGSD-V2V-US-ServiceNow_Interaction
}

moved {
  from = module.lambda-nextthink-handoff
  to   = module.BTSGSD-V2V-US-Nextthink_Handoff
}

moved {
  from = module.UpdateSessionAttributes-dev
  to   = module.BTSGSD-V2V-US-UpdateSessionAttributes
}

moved {
  from = module.lambda-snow-btsgsd-dev
  to   = module.BTSGSD-V2V-US-SNOW
}

# Keep these moves for states that still use the separate alias module.
moved {
  from = module.lex_yesno_alias[0].awscc_lex_bot_alias.this
  to   = module.lex_yesno_bot[0].awscc_lex_bot_alias.this[0]
}

moved {
  from = module.lex_yesno_alias[0].aws_lambda_permission.lex_alias
  to   = module.lex_yesno_bot[0].aws_lambda_permission.lex_alias[0]
}

moved {
  from = module.lex_yesno_alias[0].awscc_lex_resource_policy.connect
  to   = module.lex_yesno_bot[0].awscc_lex_resource_policy.connect[0]
}

moved {
  from = aws_iam_role_policy.lex_yesno_text_logs[0]
  to   = module.lex_yesno_bot[0].aws_iam_role_policy.alias_text_logs[0]
}

moved {
  from = aws_lexv2models_bot_version.lex_yesno_text_logs[0]
  to   = module.lex_yesno_bot[0].aws_lexv2models_bot_version.alias_text_logs[0]
}
