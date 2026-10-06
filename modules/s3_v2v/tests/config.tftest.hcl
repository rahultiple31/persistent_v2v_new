mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { name = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
variables {
  app_name        = "TestV2V"
  v2v_root_prefix = "V2VRoot/"
  frontend_config = {
    backendRegion      = "us-east-1"
    translationEnabled = "true"
    proxyEnabled       = "true"
  }
}
run "browser_configuration" {
  command = plan
  assert {
    condition     = aws_s3_object.frontend_config.content == "window.WebappConfig = ${jsonencode(var.frontend_config)};"
    error_message = "The configuration script must define the global object read by the Nova webapp."
  }
  assert {
    condition     = aws_s3_object.frontend_config.cache_control == "no-cache" && aws_s3_object.frontend_config.content_type == "text/javascript"
    error_message = "Browsers must execute and revalidate the generated configuration."
  }
}
run "empty_root_prefix" {
  command = plan
  variables {
    v2v_root_prefix = ""
  }
  assert {
    condition     = aws_s3_object.frontend_config.key == "frontend-config.js"
    error_message = "An empty root prefix must not introduce a leading slash."
  }
}
