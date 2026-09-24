data "aws_region" "current" {}

resource "aws_cognito_user_pool" "this" {
  name = "${var.app_name}-UserPool"

  auto_verified_attributes = ["email"]
  username_attributes      = ["email"]

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    require_uppercase                = true
    temporary_password_validity_days = 7
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    mutable             = true
    required            = false

    string_attribute_constraints {}
  }

  schema {
    name                = "connectUserId"
    attribute_data_type = "String"
    mutable             = true
    required            = false

    string_attribute_constraints {
      min_length = 36
      max_length = 36
    }
  }

  admin_create_user_config {
    invite_message_template {
      email_subject = "Your ${var.app_name} temporary password"
      email_message = "Your ${var.app_name} username is {username} and temporary password is {####}"
      sms_message   = "Your ${var.app_name} username is {username} and temporary password is {####}"
    }
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Verify your new ${var.app_name} account"
    email_message        = "The verification code to your new ${var.app_name} account is {####}"
  }

  tags = var.common_tags
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = var.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.this.id
}

resource "aws_cognito_user_pool_client" "web" {
  name         = var.frontend_client_name
  user_pool_id = aws_cognito_user_pool.this.id

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["aws.cognito.signin.user.admin", "email", "openid", "profile"]
  callback_urls                        = var.callback_urls
  logout_urls                          = var.logout_urls
  generate_secret                      = false
  prevent_user_existence_errors        = "ENABLED"
  supported_identity_providers         = ["COGNITO"]
}

resource "aws_cognito_identity_pool" "this" {
  identity_pool_name               = "${var.app_name}-IdentityPool"
  allow_unauthenticated_identities = false

  cognito_identity_providers {
    client_id               = aws_cognito_user_pool_client.web.id
    provider_name           = "cognito-idp.${data.aws_region.current.name}.amazonaws.com/${aws_cognito_user_pool.this.id}"
    server_side_token_check = false
  }

  tags = var.common_tags
}
