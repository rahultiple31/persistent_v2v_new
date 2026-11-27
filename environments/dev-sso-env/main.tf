module "lambda_internet_security_group" {
  source = "../../modules-dev-sso/lambda_internet_security_group"

  vpc_id = "vpc-0f2abb3d6596a0487" # abv-vpc-accas-dev-vpc
}

module "snow_lambda_vpc_access_policy" {
  source = "../../modules-dev-sso/iam_role_policy_attachment"

  role_arn   = "arn:aws:iam::518902362956:role/SNOW_btsgsd-dev-lambda-role"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

module "snow_lambda_vpc" {
  source = "../../modules-dev-sso/lambda_vpc_config"

  function_arn = "arn:aws:lambda:us-east-1:518902362956:function:SNOW_btsgsd-dev"

  subnet_ids = [
    "subnet-0c29b5f2c41c73d89", # abv-vpc-accas-dev-app-a
    "subnet-0fe7a72e5cef073ad", # abv-vpc-accas-dev-app-b
  ]

  security_group_ids = [
    "sg-0fccfbcc931558d50", # BTSGSD-V2V-US-LAMBDA-core-sg
    module.lambda_internet_security_group.security_group_id,
  ]

  ipv6_allowed_for_dual_stack = false

  depends_on = [
    module.lambda_internet_security_group,
    module.snow_lambda_vpc_access_policy,
  ]
}

module "lex_fr_ca" {
  source = "../../modules-dev-sso/lex_qinconnect_locale"

  bot_id        = "RCKELE93XH"
  bot_name      = "btsgsd-IT-Support_Agent-dev"
  locale_id     = "fr_CA"
  assistant_arn = "arn:aws:wisdom:us-east-1:518902362956:assistant/bc274e3f-380d-45e7-968f-2d19f92acd74"
}

module "lex_it_support_queue_fr_ca" {
  source = "../../modules-dev-sso/lex_customer_queue_locale"

  configuration = {
    account_id = "518902362956"
    region     = "us-east-1"
    bot_id     = "RCKELE93XH"
    bot_name   = "btsgsd-IT-Support_Agent-dev"
    locale_id  = "fr_CA"
  }

  # Run after AmazonQinConnect configuration and its build for the same locale.
  depends_on = [module.lex_fr_ca]
}

module "lex_yes_no_fr_ca" {
  source = "../../modules-dev-sso/lex_yes_no_locale"

  configuration = {
    account_id = "518902362956"
    region     = "us-east-1"
    bot_id     = "QT2GQYM5TT"
    bot_name   = "BTSGSD-SSO-US-yesNo"
    locale_id  = "fr_CA"

    intents = {
      repeat = [
        "répète",
        "pourrais-tu répéter?",
        "répète, s’il te plaît",
        "peux-tu répéter ça?",
        "redis-le",
        "pourrais-tu répéter, s’il te plaît?",
        "répète la question",
        "je n’ai pas entendu ça",
        "j’ai raté ça",
        "qu’est-ce que c’était?",
        "pardon",
        "peux-tu redire ça?",
      ]

      yes = [
        "oui",
        "ouais",
        "bien sûr",
        "ok",
        "d’accord",
        "ça me semble bien",
        "oui, bien sûr",
        "ouais, bien sûr",
        "oui, pourquoi pas",
        "affirmatif",
        "absolument",
        "exactement",
        "oui, s’il te plaît",
        "oui, je suis satisfait",
      ]

      no = [
        "non",
        "non, pas vraiment",
        "rien du tout",
        "je ne veux pas",
        "j’ai dit non",
        "non merci",
        "non, non",
        "refuser",
        "pas satisfait",
      ]

      dtmf = ["1", "2"]
    }
  }
}
