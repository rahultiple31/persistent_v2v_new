module "flow" {
  source = "../connect_flow_resource"

  flow = merge(var.settings, {
    name        = "BTSGSD-V2V-US-AIAgent-SurveyFlow"
    type        = "CONTACT_FLOW"
    description = "AI agent customer satisfaction survey."
    content = replace(
      replace(
        replace(
          replace(
            file("${path.module}/assets/BTSGSD-AIAgent-SurveyFlow.json"),
            "41573eb0-ae92-4b8a-bbe2-e4a32fb84801",
            var.settings.survey_data_table_id
          ),
          "arn:aws:lambda:us-east-1:518902362956:function:UpdateSessionAttributes",
          var.settings.session_attributes_lambda_arn
        ),
        "sureveyFlow_1",
        "VM_instruction_Survey"
      ),
      "arn:aws:lambda:us-east-1:518902362956:function:VMX3-VoicemailTimestamper-abbvie-sd-contactcenter-dev-us",
      var.settings.timestamper_lambda_arn
    )
    resolve_dependencies = true
  })
}
