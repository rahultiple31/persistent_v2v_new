mock_provider "aws" {}

mock_provider "aws" {
  alias = "us_east_1"

  mock_resource "aws_connect_instance" {
    defaults = {
      id  = "c227a737-3e4f-4c64-8397-2d37e318801d"
      arn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
    }
  }

  mock_resource "aws_cloudformation_stack" {
    defaults = {
      outputs = {
        DataTableArn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/data-table/11111111-1111-1111-1111-111111111111"
      }
    }
  }
}

mock_provider "aws" {
  alias = "proxy_us_east_1"
}

mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = {
        content = "{\"Version\":\"2019-10-30\",\"StartAction\":\"done\",\"Actions\":[{\"Identifier\":\"done\",\"Type\":\"EndFlowExecution\",\"Parameters\":{},\"Transitions\":{}}]}"
      }
    }
  }
}

variables {
  cognito_domain_prefix                 = "customer-number-table-test"
  connect_instance_url                  = "https://table-test.my.connect.aws"
  connect_instance_region               = "us-east-1"
  connect_admin_user_enabled            = false
  dev_ai_domain_enabled                 = false
  dev_ai_agent_enabled                  = false
  dev_support_ai_agent_enabled          = false
  dev_survey_ai_agent_enabled           = false
  dev_ai_admin_security_profile_enabled = false
}

run "table_records_and_flow_reference" {
  command = apply

  variables {
    enabled_modules = ["connect"]
  }

  override_resource {
    target = aws_cloudformation_stack.hr_transfer_data_table[0]
    values = {
      outputs = {
        DataTableArn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/data-table/22222222-2222-2222-2222-222222222222"
      }
    }
  }

  override_resource {
    target = aws_cloudformation_stack.survey_data_table[0]
    values = {
      outputs = {
        DataTableArn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/data-table/33333333-3333-3333-3333-333333333333"
      }
    }
  }

  override_resource {
    target = aws_cloudformation_stack.veeva_transfer_data_table[0]
    values = {
      outputs = {
        DataTableArn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/data-table/44444444-4444-4444-4444-444444444444"
      }
    }
  }

  override_resource {
    target = aws_cloudformation_stack.top_level_blocker_data_table[0]
    values = {
      outputs = {
        DataTableArn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/data-table/55555555-5555-5555-5555-555555555555"
      }
    }
  }

  assert {
    condition = (
      length(aws_cloudformation_stack.customer_number_data_table) == 1 &&
      aws_cloudformation_stack.customer_number_data_table[0].parameters.InstanceArn ==
      "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d" &&
      local.customer_number_template.Resources.CustomerNumberTable.Properties.Name == "CustomerNumberDataTable"
    )
    error_message = "Create CustomerNumberDataTable in the confirmed Dev Connect instance."
  }

  assert {
    condition = (
      length([for resource in values(local.customer_number_template.Resources) : resource if resource.Type == "AWS::Connect::DataTableAttribute"]) == 11 &&
      length([for resource in values(local.customer_number_template.Resources) : resource if resource.Type == "AWS::Connect::DataTableRecord"]) == 2 &&
      length([for resource in values(local.customer_number_template.Resources) : resource if try(resource.Properties.Primary, false)]) == 1 &&
      local.customer_number_template.Resources.Attributesystemphonenumber.Properties.Primary &&
      alltrue([for resource in values(local.customer_number_template.Resources) : resource.Properties.ValueType == "TEXT" if resource.Type == "AWS::Connect::DataTableAttribute"])
    )
    error_message = "Keep all 11 TEXT columns, exactly one primary column, and both CSV records."
  }

  assert {
    condition = (
      local.customer_number_template.Resources.Record18335162999.Properties.DataTableRecord.PrimaryValues[0].AttributeValue == "+18335162999" &&
      local.customer_number_template.Resources.Record18447706127.Properties.DataTableRecord.PrimaryValues[0].AttributeValue == "+18447706127" &&
      local.customer_number_rows["+18335162999"].hr_contact == "+558008920901" &&
      local.customer_number_rows["+18447706127"].hr_contact == "" &&
      local.customer_number_rows["+18447706127"].country == "" &&
      local.customer_number_rows["+18335162999"].Region == "" &&
      local.customer_number_rows["+18447706127"].amazon_voice == "Katie" &&
      local.customer_number_rows["+18335162999"].error_message == "Sorry, I didn’t get that. Let’s try again."
    )
    error_message = "Normalize phone markers while preserving blank cells, voice names, casing and Unicode text."
  }

  assert {
    condition = (
      length(local.customer_number_template.Resources.Record18335162999.Properties.DataTableRecord.Values) == 10 &&
      local.customer_number_template.Resources.Record18335162999.Properties.DataTableRecord.PrimaryValues[0].AttributeId["Fn::GetAtt"] == ["Attributesystemphonenumber", "AttributeId"] &&
      alltrue([for value in local.customer_number_template.Resources.Record18335162999.Properties.DataTableRecord.Values : contains(keys(local.customer_number_template.Resources), value.AttributeId["Fn::GetAtt"][0])])
    )
    error_message = "Record values must reference the created attribute IDs, with the phone key kept separate."
  }

  assert {
    condition = (
      output.customer_number_data_table.id == "11111111-1111-1111-1111-111111111111" &&
      local.customer_number_data_table_id == output.customer_number_data_table.id
    )
    error_message = "Export the created table ID and pass it to the main inbound module."
  }

  assert {
    condition = (
      length(aws_cloudformation_stack.hr_transfer_data_table) == 1 &&
      aws_cloudformation_stack.hr_transfer_data_table[0].parameters.InstanceArn == aws_cloudformation_stack.customer_number_data_table[0].parameters.InstanceArn &&
      local.hr_transfer_template.Resources.HRTransferTable.Properties.Name == "BTS_GSD-HR_Transfer" &&
      length([for resource in values(local.hr_transfer_template.Resources) : resource if resource.Type == "AWS::Connect::DataTableAttribute"]) == 3 &&
      length([for resource in values(local.hr_transfer_template.Resources) : resource if resource.Type == "AWS::Connect::DataTableRecord"]) == 18 &&
      length([for resource in values(local.hr_transfer_template.Resources) : resource if try(resource.Properties.Primary, false)]) == 1 &&
      local.hr_transfer_template.Resources.Attributesystemphonenumber.Properties.Primary &&
      alltrue([for resource in values(local.hr_transfer_template.Resources) : resource.Properties.ValueType == "TEXT" if resource.Type == "AWS::Connect::DataTableAttribute"])
    )
    error_message = "Create BTS_GSD-HR_Transfer with three TEXT columns, one phone primary key, and 18 records in the same Dev instance."
  }

  assert {
    condition = (
      local.hr_transfer_template.Resources.Record18000128353.Properties.DataTableRecord.PrimaryValues[0].AttributeValue == "18000128353" &&
      local.hr_transfer_rows["40190828"].country_hr == "Uruguay" &&
      local.hr_transfer_rows["40190828"].hr_contact_transfer == "5980004135985410" &&
      local.hr_transfer_rows["50321366339"].hr_contact_transfer == "" &&
      local.hr_transfer_rows["576014192633"].hr_contact_transfer == "" &&
      local.hr_transfer_rows["80077559"].hr_contact_transfer == "" &&
      alltrue([for resource in values(local.hr_transfer_template.Resources) : length(resource.Properties.DataTableRecord.Values) == 2 if resource.Type == "AWS::Connect::DataTableRecord"]) &&
      alltrue([for resource in values(local.hr_transfer_template.Resources) : alltrue([for value in resource.Properties.DataTableRecord.Values : contains(keys(local.hr_transfer_template.Resources), value.AttributeId["Fn::GetAtt"][0])]) if resource.Type == "AWS::Connect::DataTableRecord"])
    )
    error_message = "Preserve supplied digit-only numbers and empty transfers; each row must reference both non-primary attributes."
  }

  assert {
    condition = (
      output.hr_transfer_data_table.name == "BTS_GSD-HR_Transfer" &&
      output.hr_transfer_data_table.id == "22222222-2222-2222-2222-222222222222" &&
      output.hr_transfer_data_table.arn != output.customer_number_data_table.arn
    )
    error_message = "The two tables must have independent resource identifiers and outputs."
  }

  assert {
    condition = (
      length(aws_cloudformation_stack.survey_data_table) == 1 &&
      aws_cloudformation_stack.survey_data_table[0].parameters.InstanceArn == aws_cloudformation_stack.customer_number_data_table[0].parameters.InstanceArn &&
      local.survey_template.Resources.SurveyTable.Properties.Name == "BTSGSD-Survey-DataTable" &&
      length([for resource in values(local.survey_template.Resources) : resource if resource.Type == "AWS::Connect::DataTableAttribute"]) == 27 &&
      length([for resource in values(local.survey_template.Resources) : resource if resource.Type == "AWS::Connect::DataTableRecord"]) == 3 &&
      length([for resource in values(local.survey_template.Resources) : resource if try(resource.Properties.Primary, false)]) == 1 &&
      local.survey_template.Resources.AttributeLanguage.Properties.Primary &&
      alltrue([for resource in values(local.survey_template.Resources) : resource.Properties.ValueType == "TEXT" if resource.Type == "AWS::Connect::DataTableAttribute"])
    )
    error_message = "Create the survey table with 27 TEXT columns, Language as its only primary key, and all three records in Dev."
  }

  assert {
    condition = alltrue([
      for language in ["en-US", "Portuguese", "Spanish"] : (
        local.survey_template.Resources["Record${replace(language, "-", "")}"].Properties.DataTableRecord.PrimaryValues[0].AttributeValue == language &&
        local.survey_template.Resources["Record${replace(language, "-", "")}"].Properties.DataTableRecord.PrimaryValues[0].AttributeId["Fn::GetAtt"] == ["AttributeLanguage", "AttributeId"] &&
        length(local.survey_template.Resources["Record${replace(language, "-", "")}"].Properties.DataTableRecord.Values) == 26 &&
        alltrue([
          for value in local.survey_template.Resources["Record${replace(language, "-", "")}"].Properties.DataTableRecord.Values :
          local.survey_template.Resources[value.AttributeId["Fn::GetAtt"][0]].Type == "AWS::Connect::DataTableAttribute" &&
          value.AttributeValue == local.survey_rows[language][local.survey_template.Resources[value.AttributeId["Fn::GetAtt"][0]].Properties.Name]
        ])
      )
    ])
    error_message = "Each language must store 26 non-primary values using the created attribute IDs and its supplied text."
  }

  assert {
    condition = (
      local.survey_rows["en-US"].callback_1 == "<prosody rate=\"95%\">Would you like to use your number <say-as interpret-as=\"telephone\"> $.CustomerEndpoint.Address </say-as>  for callback. Please say yes or no.</prosody>" &&
      strcontains(local.survey_rows["en-US"].callback_3, "$.Attributes.CustomerPhone") &&
      strcontains(local.survey_rows["en-US"].QueuePositionDetails, "<say-as interpret-as=\"ordinal\">$.Attributes.PositionInQueue</say-as>") &&
      contains(local.survey_columns, "sureveyFlow_1") &&
      contains(local.survey_columns, "sureveyFlow_error") &&
      local.survey_rows.Portuguese.Closing == "Agradecemos e valorizamos sua participação em nossa pesquisa. Obrigado e adeus." &&
      local.survey_rows.Spanish.Closing == "Agradecemos y valoramos su participación en nuestra encuesta. Muchas gracias y hasta luego." &&
      alltrue([for language in ["Portuguese", "Spanish"] : alltrue([for column in local.survey_columns : local.survey_rows[language][column] == "" if !contains(["Language", "Closing"], column)])])
    )
    error_message = "Preserve SSML, runtime expressions, supplied header spellings, translated closing text, and all blank translation cells."
  }

  assert {
    condition = (
      output.survey_data_table.name == "BTSGSD-Survey-DataTable" &&
      output.survey_data_table.id == "33333333-3333-3333-3333-333333333333" &&
      output.survey_data_table.arn != output.customer_number_data_table.arn &&
      output.survey_data_table.arn != output.hr_transfer_data_table.arn &&
      alltrue([
        for key in ["customer_queue", "main_inbound"] :
        strcontains(local.rendered_imported_contact_flows[key].content, output.survey_data_table.id) &&
        !strcontains(local.rendered_imported_contact_flows[key].content, "41573eb0-ae92-4b8a-bbe2-e4a32fb84801") &&
        can(jsondecode(local.rendered_imported_contact_flows[key].content).Actions[0].Type)
      ]) &&
      alltrue([
        for key, flow in local.imported_flow_definitions :
        local.rendered_imported_contact_flows[key].content == file("${local.imported_flow_directory}/${flow.filename}")
        if !contains(["customer_queue", "main_inbound"], key)
      ])
    )
    error_message = "Bind both survey lookups to the new independent table ID while retaining valid flow JSON and the other exports."
  }
  assert {
    condition = (
      length(aws_cloudformation_stack.veeva_transfer_data_table) == 1 &&
      aws_cloudformation_stack.veeva_transfer_data_table[0].parameters.InstanceArn ==
      "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d" &&
      local.veeva_transfer_template.Resources.VeevaTransferTable.Properties.Name == "BTS_GSD-Veeva_Transfer" &&
      length([for resource in values(local.veeva_transfer_template.Resources) : resource if resource.Type == "AWS::Connect::DataTableAttribute"]) == 3 &&
      length([for resource in values(local.veeva_transfer_template.Resources) : resource if resource.Type == "AWS::Connect::DataTableRecord"]) == 26 &&
      length([for resource in values(local.veeva_transfer_template.Resources) : resource if try(resource.Properties.Primary, false)]) == 2 &&
      local.veeva_transfer_template.Resources.AttributecountryLATAM.Properties.Primary &&
      local.veeva_transfer_template.Resources.Attributesystemphonenumber.Properties.Primary &&
      !local.veeva_transfer_template.Resources.AttributeVeevacontact.Properties.Primary &&
      alltrue([for resource in values(local.veeva_transfer_template.Resources) : resource.Properties.ValueType == "TEXT" if resource.Type == "AWS::Connect::DataTableAttribute"])
    )
    error_message = "Create the Veeva table in Dev with three TEXT attributes, the country-and-phone primary key, and all 26 rows."
  }

  assert {
    condition = (
      local.veeva_transfer_template.Resources.RecordArgentina576014192633.Properties.DataTableRecord.Values[0].AttributeValue == "+13124799471" &&
      local.veeva_transfer_template.Resources.RecordColombia576014192633.Properties.DataTableRecord.Values[0].AttributeValue == "+13124799473" &&
      local.veeva_transfer_template.Resources.RecordJamaica1833698332.Properties.DataTableRecord.PrimaryValues[1].AttributeValue == "+1833698332" &&
      local.veeva_transfer_template.Resources.RecordDominicanRepublic18001485151.Properties.DataTableRecord.PrimaryValues[0].AttributeValue == "Dominican Republic" &&
      length([for row in values(local.veeva_transfer_rows) : row if row.system_phonenumber == "+576014192633"]) == 16 &&
      alltrue([
        for row in local.veeva_transfer_raw_rows :
        local.veeva_transfer_rows[jsonencode([row.country_LATAM, trimprefix(row.system_phonenumber, "'")])].system_phonenumber == trimprefix(row.system_phonenumber, "'") &&
        local.veeva_transfer_rows[jsonencode([row.country_LATAM, trimprefix(row.system_phonenumber, "'")])].Veeva_contact == trimprefix(row.Veeva_contact, "'") &&
        local.veeva_transfer_rows[jsonencode([row.country_LATAM, trimprefix(row.system_phonenumber, "'")])].country_LATAM == row.country_LATAM
      ])
    )
    error_message = "Keep shared phone numbers as distinct country records with their correct destinations and preserve supplied phone digits."
  }

  assert {
    condition = alltrue([
      for resource in values(local.veeva_transfer_template.Resources) : (
        length(resource.Properties.DataTableRecord.PrimaryValues) == 2 &&
        resource.Properties.DataTableRecord.PrimaryValues[0].AttributeId["Fn::GetAtt"] == ["AttributecountryLATAM", "AttributeId"] &&
        resource.Properties.DataTableRecord.PrimaryValues[1].AttributeId["Fn::GetAtt"] == ["Attributesystemphonenumber", "AttributeId"] &&
        length(resource.Properties.DataTableRecord.Values) == 1 &&
        resource.Properties.DataTableRecord.Values[0].AttributeId["Fn::GetAtt"] == ["AttributeVeevacontact", "AttributeId"]
      ) if resource.Type == "AWS::Connect::DataTableRecord"
    ])
    error_message = "Every Veeva record must reference both created primary attributes and its transfer-contact attribute."
  }

  assert {
    condition = (
      output.veeva_transfer_data_table.name == "BTS_GSD-Veeva_Transfer" &&
      output.veeva_transfer_data_table.id == "44444444-4444-4444-4444-444444444444" &&
      length(toset([
        output.customer_number_data_table.arn,
        output.hr_transfer_data_table.arn,
        output.survey_data_table.arn,
        output.veeva_transfer_data_table.arn
      ])) == 4
    )
    error_message = "Export the Veeva table ID independently from the other three tables."
  }

  assert {
    condition = (
      length(aws_cloudformation_stack.top_level_blocker_data_table) == 1 &&
      aws_cloudformation_stack.top_level_blocker_data_table[0].parameters.InstanceArn == aws_cloudformation_stack.customer_number_data_table[0].parameters.InstanceArn &&
      local.top_level_blocker_template.Resources.TopLevelBlockerTable.Properties.Name == "TopLevelBlockerMessage" &&
      length([for resource in values(local.top_level_blocker_template.Resources) : resource if resource.Type == "AWS::Connect::DataTableAttribute"]) == 2 &&
      length([for resource in values(local.top_level_blocker_template.Resources) : resource if resource.Type == "AWS::Connect::DataTableRecord"]) == 1 &&
      local.top_level_blocker_template.Resources.Attributesystemphonenumber.Properties.Primary &&
      !local.top_level_blocker_template.Resources.Attributetoplevelblockermessage.Properties.Primary &&
      alltrue([for resource in values(local.top_level_blocker_template.Resources) : resource.Properties.ValueType == "TEXT" if resource.Type == "AWS::Connect::DataTableAttribute"]) &&
      local.top_level_blocker_template.Resources.Record18335162999.Properties.DataTableRecord.PrimaryValues[0].AttributeValue == "+18335162999" &&
      local.top_level_blocker_template.Resources.Record18335162999.Properties.DataTableRecord.PrimaryValues[0].AttributeId["Fn::GetAtt"] == ["Attributesystemphonenumber", "AttributeId"] &&
      length(local.top_level_blocker_template.Resources.Record18335162999.Properties.DataTableRecord.Values) == 1 &&
      local.top_level_blocker_template.Resources.Record18335162999.Properties.DataTableRecord.Values[0].AttributeId["Fn::GetAtt"] == ["Attributetoplevelblockermessage", "AttributeId"] &&
      local.top_level_blocker_template.Resources.Record18335162999.Properties.DataTableRecord.Values[0].AttributeValue == ""
    )
    error_message = "Create TopLevelBlockerMessage in Dev with two TEXT columns, a normalized phone primary key, and the supplied empty message."
  }

  assert {
    condition = (
      output.top_level_blocker_data_table.name == "TopLevelBlockerMessage" &&
      output.top_level_blocker_data_table.id == "55555555-5555-5555-5555-555555555555" &&
      length(toset([
        output.customer_number_data_table.arn,
        output.hr_transfer_data_table.arn,
        output.survey_data_table.arn,
        output.veeva_transfer_data_table.arn,
        output.top_level_blocker_data_table.arn
      ])) == 5 &&
      [for action in jsondecode(local.rendered_imported_contact_flows.main_inbound.content).Actions : action.Parameters.DataTableId if action.Identifier == "TopLevelBlocker_Message"] == [output.top_level_blocker_data_table.id] &&
      [for action in jsondecode(local.rendered_imported_contact_flows.main_inbound.content).Actions : action.Parameters.Queries[0].PrimaryValues[0].AttributeName if action.Identifier == "TopLevelBlocker_Message"] == ["system_phonenumber"] &&
      [for action in jsondecode(local.rendered_imported_contact_flows.main_inbound.content).Actions : action.Parameters.Queries[0].PrimaryValues[0].Value if action.Identifier == "TopLevelBlocker_Message"] == ["$.SystemEndpoint.Address"] &&
      [for action in jsondecode(local.rendered_imported_contact_flows.main_inbound.content).Actions : action.Parameters.Queries[0].Attributes if action.Identifier == "TopLevelBlocker_Message"] == [["toplevelblocker_message"]] &&
      !strcontains(local.rendered_imported_contact_flows.main_inbound.content, "e0917ae9-956c-4e02-b73f-43150201aa7f")
    )
    error_message = "Bind the existing main inbound blocker lookup to the new independent table ID while preserving its key and message column."
  }
}

run "other_targets_exclude_customer_number_table" {
  command = plan

  variables {
    enabled_modules = []
  }

  assert {
    condition = (
      length(aws_cloudformation_stack.customer_number_data_table) == 0 && output.customer_number_data_table == null &&
      length(aws_cloudformation_stack.hr_transfer_data_table) == 0 && output.hr_transfer_data_table == null &&
      length(aws_cloudformation_stack.survey_data_table) == 0 && output.survey_data_table == null &&
      length(aws_cloudformation_stack.veeva_transfer_data_table) == 0 && output.veeva_transfer_data_table == null &&
      length(aws_cloudformation_stack.top_level_blocker_data_table) == 0 && output.top_level_blocker_data_table == null &&
      length(local.rendered_imported_contact_flows) == 0
    )
    error_message = "Only the Connect target should create the data tables and render their imported flows."
  }
}
