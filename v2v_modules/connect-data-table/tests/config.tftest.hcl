mock_provider "aws" {}

variables {
  connect_instance_arn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
}

run "customer_number" {
  command = plan

  variables {
    profile = "customer-number"
  }

  assert {
    condition = (
      aws_cloudformation_stack.this.name == "BTSGSD-V2V-US-BTS-GSD-CustomerNumber" &&
      aws_cloudformation_stack.this.parameters.InstanceArn == var.connect_instance_arn &&
      aws_cloudformation_stack.this.template_body == local.template_json &&
      length(aws_s3_object.template) == 0 &&
      length(local.rows) == 19 &&
      local.template.Resources.Attributecountry.Properties.Primary &&
      local.template.Resources.Attributesystemphonenumber.Properties.Primary
    )
    error_message = "Keep the existing customer stack, inline template, instance, composite key, and 19 records."
  }
  assert {
    condition = (
      length([
        for resource in jsondecode(local.template_json).Resources : resource
        if resource.Type == "AWS::Connect::DataTableAttribute"
      ]) == 11 &&
      length([
        for resource in jsondecode(local.template_json).Resources : resource
        if resource.Type == "AWS::Connect::DataTableRecord"
      ]) == 19 &&
      alltrue([
        for resource in jsondecode(local.template_json).Resources :
        length(resource.Properties.DataTableRecord.PrimaryValues) == 2
        if resource.Type == "AWS::Connect::DataTableRecord"
      ])
    )
    error_message = "Replace the routing dataset with exactly 19 records and 11 attributes while retaining the composite primary key."
  }

  assert {
    condition = (
      local.rows[jsonencode(["United States", "+18335162999"])].region == "LATAM" &&
      local.rows[jsonencode(["USTest", "+18557114065"])].veeva_contact == "+13124799473" &&
      local.rows[jsonencode(["Test2", "+18557117645"])].region == "NORAM" &&
      local.rows[jsonencode(["MexicoTest", "+528003230767"])].hr_contact == "+528008770373" &&
      local.rows[jsonencode(["ArgentinaTest", "+548001120636"])].language_code == "pt-BR" &&
      local.rows[jsonencode(["Colombia_TravelLine", "+576014192633"])].medcom_contact == "+13152949458" &&
      !contains(keys(local.rows), jsonencode(["Colombia", "+576014192633"])) &&
      local.rows[jsonencode(["", "+12"])].amazon_voice == "Aditi" &&
      local.rows[jsonencode(["Peru", "+5180077559"])].hr_contact == ""
    )
    error_message = "Preserve the supplied test-country rows, routing destinations, language choices, blank cells, and normalized phone numbers; omit superseded records."
  }
}

run "prompt" {
  command = plan

  variables {
    profile = "prompt"
    template_bucket = {
      name                 = "test-v2v-prompt-template-bucket"
      regional_domain_name = "test-v2v-prompt-template-bucket.s3.us-east-1.amazonaws.com"
    }
  }

  assert {
    condition = (
      aws_cloudformation_stack.this.name == "BTSGSD-V2V-US-SurveyDataTable" &&
      aws_cloudformation_stack.this.parameters.InstanceArn == var.connect_instance_arn &&
      aws_cloudformation_stack.this.template_url == "https://${var.template_bucket.regional_domain_name}/data-tables/prompt/${sha256(local.template_json)}.json" &&
      aws_s3_object.template[0].bucket == var.template_bucket.name &&
      aws_s3_object.template[0].content == local.template_json &&
      aws_s3_object.template[0].server_side_encryption == "AES256" &&
      local.template.Resources.AttributeLanguage.Properties.Primary &&
      length(local.columns) == 49 &&
      toset(keys(local.rows)) == toset(["en-US", "es-MX", "pt-BR"])
    )
    error_message = "Keep the prompt stack, instance, encrypted S3 template URL/content/key, Language key, and three 49-column rows."
  }
  assert {
    condition = (
      length([
        for resource in jsondecode(local.template_json).Resources : resource
        if resource.Type == "AWS::Connect::DataTableAttribute"
      ]) == 49 &&
      length([
        for resource in jsondecode(local.template_json).Resources : resource
        if resource.Type == "AWS::Connect::DataTableRecord"
      ]) == 3 &&
      alltrue([
        for resource in jsondecode(local.template_json).Resources :
        length(resource.Properties.DataTableRecord.Values) == 48
        if resource.Type == "AWS::Connect::DataTableRecord"
      ])
    )
    error_message = "Publish all 49 attributes and 48 prompt values for each of the three language records."
  }

  assert {
    condition = (
      local.rows["en-US"].OpeningPrompt == "Thanks $.Attributes.FirstName, you're all verified. How can I help you today?" &&
      local.rows["en-US"].Welcome_Greeting == "Thank you for calling the <sub alias=\"Abb-Vee\">AbbVie</sub> Service Desk. I’m your virtual assistant." &&
      local.rows["es-MX"].OpeningPrompt == "Gracias, $.Attributes.FirstName, ya están todos verificados. ¿En qué puedo ayudarte hoy?" &&
      local.rows["pt-BR"].OpeningPrompt == "Obrigado, $.Attributes.FirstName, todos vocês estão verificados. Em que posso ajudar hoje?" &&
      alltrue([
        for language in ["es-MX", "pt-BR"] :
        local.rows[language].ff_unverified_message == "" &&
        local.rows[language].liveAgent_transfer_message == ""
      ])
    )
    error_message = "Preserve supplied prompt text, Connect runtime placeholders, and blank untranslated cells."
  }

  assert {
    condition = (
      local.rows["pt-BR"].callback_InvalidNumber == "<prosody rate=\"95%\"><break time=\"0.2s\"/>Lamentamos não ter captado o número para o qual você solicitou que entrássemos em contato.</prosody>" &&
      strcontains(local.rows["pt-BR"].callback_1, "interpret-as=\"telephone\"") &&
      strcontains(local.rows["pt-BR"].callback_retryMessage, "<break time=\"0.2s\"/>")
    )
    error_message = "Normalize malformed SSML attributes while reading the prompt CSV."
  }
}
