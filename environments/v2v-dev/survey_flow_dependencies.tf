# The Yes/No bot is deployed in the existing lex_bot state, outside connect.
# An explicit alias ARN can be supplied through the existing override variable.
data "terraform_remote_state" "survey_lex" {
  count   = local.deploy_connect && var.lex_yesno_bot_alias_arn == null ? 1 : 0
  backend = "s3"

  config = {
    bucket  = "bts-cloud-terraform-tfstate"
    key     = "terraform-state/v2v/us-east-1/lex_bot/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}
