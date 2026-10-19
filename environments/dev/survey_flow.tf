data "external" "survey_flow_dependencies" {
  count = local.deploy_connect ? 1 : 0

  program = [
    var.connect_flow_python_executable,
    "${path.module}/../../modules/connect/scripts/resolve_customer_queue_dependencies.py"
  ]

  query = {
    region         = "us-east-1"
    instance_id    = module.connect_us_east_1[0].instance_id
    instance_arn   = module.connect_us_east_1[0].instance_arn
    name_overrides = jsonencode(var.connect_customer_queue_dependency_names)

    content = replace(
      replace(
        file("${path.module}/metadata/contact-flows/BTSGSD-AIAgent-SurveyFlow.json"),
        "41573eb0-ae92-4b8a-bbe2-e4a32fb84801",
        local.survey_data_table_id
      ),
      "arn:aws:lambda:us-east-1:518902362956:function:UpdateSessionAttributes",
      module.UpdateSessionAttributes-dev[0].lambda_arn
    )
  }
}

resource "aws_connect_contact_flow" "survey" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  instance_id = module.connect_us_east_1[0].instance_id
  name        = "BTSGSD-AIAgent-SurveyFlow"
  description = "AI agent customer satisfaction survey."
  type        = "CONTACT_FLOW"
  content     = data.external.survey_flow_dependencies[0].result.content

  tags = merge(local.common_tags, {
    Name = "BTSGSD-AIAgent-SurveyFlow"
  })

  depends_on = [module.UpdateSessionAttributes-dev]

  lifecycle {
    precondition {
      condition     = module.connect_us_east_1[0].instance_id == "c227a737-3e4f-4c64-8397-2d37e318801d"
      error_message = "Deploy the survey only to btsgsd-dev-us-east-1."
    }
  }
}

output "survey_flow_arn" {
  value = try(aws_connect_contact_flow.survey[0].arn, null)
}
