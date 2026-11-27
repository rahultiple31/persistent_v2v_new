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
