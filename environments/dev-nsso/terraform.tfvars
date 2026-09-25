environment            = "dev-nsso"
project_name           = "btsgsd"
aws_region             = "us-east-1"
resource_name_prefix   = "btsgsd-dev-nsso-us-east-1"
contact_center_alias   = "btsgsd"
connect_instance_alias = "btsgsd-dev-nsso-us-east-1"
connect_name_suffix    = "connect-saml"
connect_admin_user_enabled = true
connect_admin_first_name   = "Lokesh"
connect_admin_last_name    = "Kothapally"
connect_admin_username     = "lokesh.kothapally@abbvie.com"
connect_admin_email        = "lokesh.kothapally@abbvie.com"

common_tags = {
  CostCenter = "contact-center"
  Owner      = "platform-engineering"
}

cognito_domain_prefix   = "btsgsd-dev-nsso-us-east-1"
cognito_callback_urls   = ["https://localhost:5173"]
cognito_logout_urls     = ["https://localhost:5173"]
connect_instance_url    = "https://btsgsd-dev-nsso-us-east-1.my.connect.aws"
connect_instance_region = "us-east-1"
transcribe_region       = "us-east-1"
translate_region        = "us-east-1"
translate_proxy_enabled = true
polly_region            = "us-east-1"
polly_proxy_enabled     = true
deploy_v2v_assets       = true
app_name                = "btsgsd-dev-nsso-us-east-1"
frontend_client_name    = "btsgsd-dev-nsso-us-east-1-frontend"
ssm_hierarchy           = "/btsgsd-dev-nsso-us-east-1/"
