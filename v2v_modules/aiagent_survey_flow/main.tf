locals {
  survey_flow_source = jsondecode(file("${path.module}/assets/BTSGSD-AIAgent-SurveyFlow.json"))
  survey_flow_content = replace(
    replace(
      replace(
        replace(
          file("${path.module}/assets/BTSGSD-AIAgent-SurveyFlow.json"),
          "__SURVEY_DATA_TABLE_ID__",
          var.settings.survey_data_table_id
        ),
        "__TIMESTAMPER_LAMBDA_ARN__",
        var.settings.timestamper_lambda_arn
      ),
      "__YESNO_BOT_ALIAS_ARN__",
      var.settings.yesno_bot_alias_arn
    ),
    "__VOICEMAIL_FLOW_MODULE_ID__",
    var.settings.voicemail_flow_module_id
  )
}

module "flow" {
  source = "../connect_flow_resource"

  flow = merge(var.settings, {
    name                 = "BTSGSD-V2V-US-SurveyFlow"
    type                 = "CONTACT_FLOW"
    description          = "AI agent customer satisfaction survey."
    content              = local.survey_flow_content
    resolve_dependencies = false
  })
}
