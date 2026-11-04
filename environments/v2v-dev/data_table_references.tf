# Compatibility inputs for existing flows and outputs.
locals {
  survey_data_table_id         = try(module.survey_data_table[0].deployment.id, null)
  survey_data_table_stack_name = "BTSGSD-V2V-US-SurveyDataTable"

  # Keep voicemail's lookup independent of managed table deployment.
  voicemail_prompt_data_table_id = try(
    element(
      reverse(split(
        "/",
        data.aws_cloudformation_stack.survey_data_table[0].outputs["DataTableArn"]
      )),
      0
    ),
    null
  )
}

data "aws_cloudformation_stack" "survey_data_table" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  name = local.survey_data_table_stack_name
}
