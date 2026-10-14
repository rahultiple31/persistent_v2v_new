# Creates CustomerNumberDataTable with the supplied CSV rows. Phone numbers
# lose Excel's leading apostrophe so the primary key matches the dialed number.
locals {
  customer_number_csv = <<-CSV
"system_phonenumber","amazon_speaking_engine","amazon_speaking_style","amazon_voice","country","error_message","hr_contact","language_code","language_name","Region","welcome_prompt"
"'+18335162999","neural","conversational","Joanna","United States","Sorry, I didn’t get that. Let’s try again.","'+558008920901","en-US","English","","Welcome to AbbVie Service Desk. Please briefly describe your issue."
"'+18447706127","neural","conversational","Katie","","Sorry, I didn’t get that. Let’s try again.","","en-US","English","","Welcome to AbbVie Service Desk. Please briefly describe your issue."
CSV

  customer_number_raw_rows = csvdecode(trimspace(local.customer_number_csv))
  customer_number_columns  = keys(local.customer_number_raw_rows[0])

  customer_number_rows = {
    for row in local.customer_number_raw_rows :
    trimprefix(trimspace(row.system_phonenumber), "'") => {
      for column, value in row :
      column => (
        contains(["system_phonenumber", "hr_contact"], column)
        ? trimprefix(trimspace(value), "'")
        : value
      )
    }
  }

  customer_number_template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Amazon Connect CustomerNumberDataTable configuration."

    Parameters = {
      InstanceArn = {
        Type = "String"
      }
    }

    Resources = merge(
      {
        CustomerNumberTable = {
          Type = "AWS::Connect::DataTable"
          Properties = {
            InstanceArn    = { Ref = "InstanceArn" }
            Name           = "CustomerNumberDataTable"
            Description    = "Language and greeting configuration by dialed phone number."
            Status         = "PUBLISHED"
            TimeZone       = "UTC"
            ValueLockLevel = "NONE"

            Tags = [
              for key, value in merge(local.common_tags, {
                Name = "CustomerNumberDataTable"
                }) : {
                Key   = key
                Value = value
              }
            ]
          }
        }
      },
      {
        for column in local.customer_number_columns :
        "Attribute${replace(column, "_", "")}" => {
          Type = "AWS::Connect::DataTableAttribute"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["CustomerNumberTable", "Arn"] }
            Name         = column
            ValueType    = "TEXT"
            Primary      = column == "system_phonenumber"
          }
        }
      },
      {
        for phone_number, row in local.customer_number_rows :
        "Record${replace(phone_number, "+", "")}" => {
          Type = "AWS::Connect::DataTableRecord"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["CustomerNumberTable", "Arn"] }

            DataTableRecord = {
              PrimaryValues = [
                {
                  AttributeId = {
                    "Fn::GetAtt" = [
                      "Attributesystemphonenumber",
                      "AttributeId"
                    ]
                  }
                  AttributeValue = phone_number
                }
              ]

              Values = [
                for column in local.customer_number_columns : {
                  AttributeId = {
                    "Fn::GetAtt" = [
                      "Attribute${replace(column, "_", "")}",
                      "AttributeId"
                    ]
                  }
                  AttributeValue = row[column]
                }
                if column != "system_phonenumber"
              ]
            }
          }
        }
      }
    )

    Outputs = {
      DataTableArn = {
        Value = {
          "Fn::GetAtt" = ["CustomerNumberTable", "Arn"]
        }
      }
    }
  }

  customer_number_data_table_id = try(element(
    reverse(split("/", aws_cloudformation_stack.customer_number_data_table[0].outputs["DataTableArn"])),
    0
  ), null)
}

resource "aws_cloudformation_stack" "customer_number_data_table" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  name          = "btsgsd-dev-CustomerNumberDataTable"
  template_body = jsonencode(local.customer_number_template)

  parameters = {
    InstanceArn = module.connect_us_east_1[0].instance_arn
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      condition = (
        module.connect_us_east_1[0].instance_arn ==
        "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
      )
      error_message = "CustomerNumberDataTable must be created in the confirmed Dev Connect instance."
    }

    precondition {
      condition = alltrue([
        for phone_number in keys(local.customer_number_rows) :
        can(regex("^\\+[1-9][0-9]{1,14}$", phone_number))
      ])
      error_message = "system_phonenumber values must use E.164 format."
    }
  }
}

output "customer_number_data_table" {
  description = "CustomerNumberDataTable identifiers for flow configuration."

  value = try({
    name = "CustomerNumberDataTable"
    arn  = aws_cloudformation_stack.customer_number_data_table[0].outputs["DataTableArn"]
    id   = local.customer_number_data_table_id
  }, null)
}

# A separate HR transfer table in the same Terraform file. Phone numbers are
# TEXT and retain the digit-only formatting supplied in the CSV.
locals {
  hr_transfer_csv = <<-CSV
"system_phonenumber","country_hr","hr_contact_transfer"
"18000128353","Colombia","57018005189572"
"18001485151","Dominican Republic","18665486437"
"18002524415","United States","18446634748"
"18004078577","Canada","18553007019"
"18336980332","Jamaica","18552013947"
"18883361367","Trinidad and Tobago","18665462622"
"40190828","Uruguay","5980004135985410"
"50321366339","El Salvador",""
"50769789714","Panama","5078000086"
"576014192633","Nicaragua",""
"8000121897","Costa Rica","5068000320022"
"8000474521","Brazil","5508008920901"
"8000835964","Mexico","528008770373"
"8002661683","Argentina","5408003454866"
"800395181","Chile","56800914883"
"80077559","Peru",""
"8552692014","Guatemala","50224582811"
"8663806011","Puerto Rico","18553075401"
CSV

  hr_transfer_raw_rows = csvdecode(trimspace(local.hr_transfer_csv))
  hr_transfer_columns  = keys(local.hr_transfer_raw_rows[0])

  hr_transfer_rows = {
    for row in local.hr_transfer_raw_rows :
    row.system_phonenumber => row
  }

  hr_transfer_template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Amazon Connect HR country and transfer-number data."

    Parameters = {
      InstanceArn = {
        Type = "String"
      }
    }

    Resources = merge(
      {
        HRTransferTable = {
          Type = "AWS::Connect::DataTable"
          Properties = {
            InstanceArn    = { Ref = "InstanceArn" }
            Name           = "BTS_GSD-HR_Transfer"
            Description    = "HR country and transfer number by system phone number."
            Status         = "PUBLISHED"
            TimeZone       = "UTC"
            ValueLockLevel = "NONE"

            Tags = [
              for key, value in merge(local.common_tags, {
                Name = "BTS_GSD-HR_Transfer"
                }) : {
                Key   = key
                Value = value
              }
            ]
          }
        }
      },
      {
        for column in local.hr_transfer_columns :
        "Attribute${replace(column, "_", "")}" => {
          Type = "AWS::Connect::DataTableAttribute"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["HRTransferTable", "Arn"] }
            Name         = column
            ValueType    = "TEXT"
            Primary      = column == "system_phonenumber"
          }
        }
      },
      {
        for phone_number, row in local.hr_transfer_rows :
        "Record${phone_number}" => {
          Type = "AWS::Connect::DataTableRecord"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["HRTransferTable", "Arn"] }

            DataTableRecord = {
              PrimaryValues = [
                {
                  AttributeId = {
                    "Fn::GetAtt" = [
                      "Attributesystemphonenumber",
                      "AttributeId"
                    ]
                  }
                  AttributeValue = phone_number
                }
              ]

              Values = [
                for column in local.hr_transfer_columns : {
                  AttributeId = {
                    "Fn::GetAtt" = [
                      "Attribute${replace(column, "_", "")}",
                      "AttributeId"
                    ]
                  }
                  AttributeValue = row[column]
                }
                if column != "system_phonenumber"
              ]
            }
          }
        }
      }
    )

    Outputs = {
      DataTableArn = {
        Value = {
          "Fn::GetAtt" = ["HRTransferTable", "Arn"]
        }
      }
    }
  }

  hr_transfer_data_table_id = try(element(
    reverse(split(
      "/",
      aws_cloudformation_stack.hr_transfer_data_table[0].outputs["DataTableArn"]
    )),
    0
  ), null)
}

resource "aws_cloudformation_stack" "hr_transfer_data_table" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  name          = "btsgsd-dev-HRTransferDataTable"
  template_body = jsonencode(local.hr_transfer_template)

  parameters = {
    InstanceArn = module.connect_us_east_1[0].instance_arn
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      condition = (
        module.connect_us_east_1[0].instance_arn ==
        "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
      )
      error_message = "The HR transfer table must be created in the confirmed Dev Connect instance."
    }

    precondition {
      condition = alltrue([
        for phone_number in keys(local.hr_transfer_rows) :
        can(regex("^[0-9]+$", phone_number))
      ])
      error_message = "system_phonenumber values must contain digits only."
    }
  }
}

output "hr_transfer_data_table" {
  description = "Identifiers for the Connect HR transfer table named BTS_GSD-HR_Transfer."

  value = try({
    name = "BTS_GSD-HR_Transfer"
    arn  = aws_cloudformation_stack.hr_transfer_data_table[0].outputs["DataTableArn"]
    id   = local.hr_transfer_data_table_id
  }, null)
}

# Preserve the supplied column names, SSML and empty translation cells.
locals {
  survey_english_row = {
    Language               = "en-US"
    callback_1             = "<prosody rate=\"95%\">Would you like to use your number <say-as interpret-as=\"telephone\"> $.CustomerEndpoint.Address </say-as>  for callback. Please say yes or no.</prosody>"
    callback_2             = "<prosody rate=\"95%\"><break time = '0.2s'/>To place your call in the  virtual queue, please enter your phone number starting  with your country code. For  example: Plus 1<say-as interpret-as=\"telephone\"> 1234567890</say-as></prosody>"
    callback_3             = "<prosody rate=\"95%\"><break time = '0.2s'/>Thank you for leaving your phone number.  We will contact you on  <say-as interpret-as=\"telephone\"> $.Attributes.CustomerPhone </say-as>  Is this correct? Please say yes or no..</prosody>"
    callback_confirmed     = "<prosody rate=\"95%\"><break time = '0.2s'/>Your position in the virtual  queue has been confirmed.  You will receive a call back  from the next available  agent. Thank you and  goodbye</prosody>"
    callback_error         = "<prosody rate=\"95%\"><break time = '0.2s'/>We're sorry, but the callback system has encountered an error and cannot process your request at this time. Please try again later. Thank you for calling. Goodbye.</prosody>"
    callback_InvalidNumber = "<prosody rate=\"95%\"><break time = '0.2s'/>We are sorry we did not  capture the number you  requested to be called back  on. Please try again.</prosody>"
    callback_retryMessage  = "<prosody rate=\"95%\"><break time = '0.2s'/>We're sorry, but the retry limit has been reached and your request cannot be processed at this time. Please try again later. Thank you for calling. Goodbye.</prosody>"
    Closing                = "<prosody rate=\"95%\"><break time = '0.2s'/>We appreciate and value your  participation in our survey. Thank You and Good  Bye.</prosody>"
    Global_r_1             = "Sorry, I didn't get that"
    Global_r_2             = "Sorry, I still didn't get that"
    Global_t_1             = "Sorry, I didn't hear anything"
    Global_t_2             = "Sorry, I still didn't hear anything"
    Hold_Announcement      = "<prosody rate=\"95%\"><break time = '0.2s'/>Your call has been placed  into a queue. Please hold for  the next available agent.</prosody>"
    QA_Announcement        = "<prosody rate=\"95%\"><break time = '0.2s'/>Your call may be recorded  for quality assurance and  training purposes</prosody>"
    queueErrorMessage      = "<prosody rate=\"95%\"><break time = '0.2s'/>We're sorry, but something went wrong and your request cannot be processed at this time. Please try again later. Thank you for calling. Goodbye.</prosody>"
    QueueMenu              = "<prosody rate=\"95%\"><break time = '0.2s'/>Thank you for holding. All of our technicians are assisting other callers. If you would like to keep your position in queue and have a technician call you back please say: callback. If you would like to leave a voicemail please say: Voicemail Otherwise please continue to hold</prosody>"
    QueuePositionDetails   = "<prosody rate=\"95%\"><break time = '0.2s'/>Your estimated wait time is  $.Attributes.EstimatedWaitTime and you are the <say-as interpret-as=\"ordinal\">$.Attributes.PositionInQueue</say-as>  caller in line.</prosody>"
    sureveyFlow_1          = "<prosody rate=\"95%\"><break time = '0.2s'/>After the beep, please record your comments. When you have finished recording , please hit the # (pound key).</prosody>"
    sureveyFlow_error      = "<prosody rate=\"95%\"><break time = '0.2s'/>The Survey  system has encountered an error and is unable to process your request at this time. Please try again later.</prosody>"
    surveyAnnouncement     = "<prosody rate=\"95%\"><break time = '0.2s'/>After this call we would  appreciate your response to  a brief survey about your  experience with the agent.</prosody>"
    surveyBot_initialize   = "<prosody rate=\"95%\">Thank you for speaking with us today <break time=\"200ms\"/> please stay on the line while we transfer you to a brief survey about your experience.</prosody>"
    voicemail_confirmation = "<prosody rate=\"95%\">Your request has been  queued. You will receive a  callback from the next  available agent. Thank you  and good bye..</prosody>"
    voicemail_errorMessage = "<prosody rate=\"95%\">The voicemail system has encountered an error and is unable to process your request at this time. Please try again later. Thank you for calling. Goodbye.</prosody>"
    voicemail_queueFlow    = "<prosody rate=\"95%\">At the tone, please leave your name, phone number, UPI ID, and a brief message. An agent will get back to you during business hours. When you have finished speaking, you may simply stop talking or hang up. Please begin after the tone..</prosody>"
    voiceMailModuleError   = "<prosody rate=\"95%\"><break time = '0.2s'/>The voicemail system has encountered an error. We are placing you in queue.</prosody>"
    voiceMailSaved         = "<prosody rate=\"95%\">Your voicemail has been saved.</prosody>"
  }

  survey_columns   = keys(local.survey_english_row)
  survey_empty_row = { for column in local.survey_columns : column => "" }
  survey_rows = {
    "en-US" = local.survey_english_row
    Portuguese = merge(local.survey_empty_row, {
      Language = "Portuguese"
      Closing  = "Agradecemos e valorizamos sua participação em nossa pesquisa. Obrigado e adeus."
    })
    Spanish = merge(local.survey_empty_row, {
      Language = "Spanish"
      Closing  = "Agradecemos y valoramos su participación en nuestra encuesta. Muchas gracias y hasta luego."
    })
  }

  survey_template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Amazon Connect survey, callback and voicemail messages."
    Parameters = {
      InstanceArn = { Type = "String" }
    }

    Resources = merge(
      {
        SurveyTable = {
          Type = "AWS::Connect::DataTable"
          Properties = {
            InstanceArn    = { Ref = "InstanceArn" }
            Name           = "BTSGSD-Survey-DataTable"
            Description    = "Survey, callback and voicemail configuration by language."
            Status         = "PUBLISHED"
            TimeZone       = "UTC"
            ValueLockLevel = "NONE"
            Tags = [
              for key, value in merge(local.common_tags, { Name = "BTSGSD-Survey-DataTable" }) : {
                Key   = key
                Value = value
              }
            ]
          }
        }
      },
      {
        for column in local.survey_columns : "Attribute${replace(column, "_", "")}" => {
          Type = "AWS::Connect::DataTableAttribute"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["SurveyTable", "Arn"] }
            Name         = column
            ValueType    = "TEXT"
            Primary      = column == "Language"
          }
        }
      },
      {
        for language, row in local.survey_rows : "Record${replace(language, "-", "")}" => {
          Type = "AWS::Connect::DataTableRecord"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["SurveyTable", "Arn"] }
            DataTableRecord = {
              PrimaryValues = [
                {
                  AttributeId    = { "Fn::GetAtt" = ["AttributeLanguage", "AttributeId"] }
                  AttributeValue = language
                }
              ]
              Values = [
                for column in local.survey_columns : {
                  AttributeId    = { "Fn::GetAtt" = ["Attribute${replace(column, "_", "")}", "AttributeId"] }
                  AttributeValue = row[column]
                }
                if column != "Language"
              ]
            }
          }
        }
      }
    )

    Outputs = {
      DataTableArn = { Value = { "Fn::GetAtt" = ["SurveyTable", "Arn"] } }
    }
  }

  survey_data_table_id = try(element(
    reverse(split("/", aws_cloudformation_stack.survey_data_table[0].outputs["DataTableArn"])),
    0
  ), null)
}

resource "aws_cloudformation_stack" "survey_data_table" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  name          = "btsgsd-dev-SurveyDataTable"
  template_body = jsonencode(local.survey_template)
  parameters = {
    InstanceArn = module.connect_us_east_1[0].instance_arn
  }
  tags = local.common_tags

  lifecycle {
    precondition {
      condition = (
        module.connect_us_east_1[0].instance_arn ==
        "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
      )
      error_message = "The survey table must be created in the confirmed Dev Connect instance."
    }
  }
}

output "survey_data_table" {
  description = "BTSGSD-Survey-DataTable identifiers for flow configuration."
  value = try({
    name = "BTSGSD-Survey-DataTable"
    arn  = aws_cloudformation_stack.survey_data_table[0].outputs["DataTableArn"]
    id   = local.survey_data_table_id
  }, null)
}

# Countries share system phone numbers, so both columns form the primary key.
# Remove Excel's leading apostrophe from phone cells and retain the supplied digits.
locals {
  veeva_transfer_csv = <<-CSV
"country_LATAM","system_phonenumber","Veeva_contact"
"Argentina","'+548002661683","'+13124799471"
"Argentina","'+576014192633","'+13124799471"
"Bahamas","'+18336980331","'+13124799471"
"Bahamas","'+576014192633","'+13124799471"
"Barbados","'+576014192633","'+13124799471"
"Chile","'+56800395181","'+13124799471"
"Chile","'+576014192633","'+13124799471"
"Colombia","'+5718000128353","'+13124799473"
"Colombia","'+576014192633","'+13124799473"
"Costa Rica","'+576014192633","'+13124799473"
"Curacao","'+576014192633","'+13124799471"
"Dominican Republic","'+18001485151","'+13124799473"
"Dominican Republic","'+576014192633","'+13124799473"
"El Salvador","'+576014192633","'+13124799473"
"Guatemala","'+576014192633","'+13124799473"
"Honduras","'+576014192633","'+13124799473"
"Jamaica","'+1833698332","'+13124799471"
"Jamaica","'+576014192633","'+13124799471"
"Mexico","'+528000835964","'+13124799473"
"Nicaragua","'+576014192633","'+13124799473"
"Panama","'+50769789714","'+13124799473"
"Peru","'+5180077559","'+13124799473"
"Puerto Rico","'+18663806011","'+13124799471"
"Trinidad and Tobago","'+576014192633","'+13124799471"
"Uruguay","'+576014192633","'+13124799473"
"Venezuela","'+576014192633","'+13124799471"
CSV

  veeva_transfer_raw_rows        = csvdecode(trimspace(local.veeva_transfer_csv))
  veeva_transfer_columns         = keys(local.veeva_transfer_raw_rows[0])
  veeva_transfer_primary_columns = ["country_LATAM", "system_phonenumber"]
  veeva_transfer_rows = {
    for row in local.veeva_transfer_raw_rows :
    jsonencode([row.country_LATAM, trimprefix(trimspace(row.system_phonenumber), "'")]) => {
      for column, value in row : column => (
        contains(["system_phonenumber", "Veeva_contact"], column)
        ? trimprefix(trimspace(value), "'")
        : value
      )
    }
  }

  veeva_transfer_template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Amazon Connect Veeva transfer contacts by country and system phone number."
    Parameters = {
      InstanceArn = { Type = "String" }
    }

    Resources = merge(
      {
        VeevaTransferTable = {
          Type = "AWS::Connect::DataTable"
          Properties = {
            InstanceArn    = { Ref = "InstanceArn" }
            Name           = "BTS_GSD-Veeva_Transfer"
            Description    = "Veeva transfer contact by LATAM country and system phone number."
            Status         = "PUBLISHED"
            TimeZone       = "UTC"
            ValueLockLevel = "NONE"
            Tags = [
              for key, value in merge(local.common_tags, { Name = "BTS_GSD-Veeva_Transfer" }) : {
                Key   = key
                Value = value
              }
            ]
          }
        }
      },
      {
        for column in local.veeva_transfer_columns : "Attribute${replace(column, "_", "")}" => {
          Type = "AWS::Connect::DataTableAttribute"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["VeevaTransferTable", "Arn"] }
            Name         = column
            ValueType    = "TEXT"
            Primary      = contains(local.veeva_transfer_primary_columns, column)
          }
        }
      },
      {
        for row in values(local.veeva_transfer_rows) :
        "Record${replace(row.country_LATAM, "/[^A-Za-z0-9]/", "")}${replace(row.system_phonenumber, "+", "")}" => {
          Type = "AWS::Connect::DataTableRecord"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["VeevaTransferTable", "Arn"] }
            DataTableRecord = {
              PrimaryValues = [
                for column in local.veeva_transfer_primary_columns : {
                  AttributeId    = { "Fn::GetAtt" = ["Attribute${replace(column, "_", "")}", "AttributeId"] }
                  AttributeValue = row[column]
                }
              ]
              Values = [
                for column in local.veeva_transfer_columns : {
                  AttributeId    = { "Fn::GetAtt" = ["Attribute${replace(column, "_", "")}", "AttributeId"] }
                  AttributeValue = row[column]
                }
                if !contains(local.veeva_transfer_primary_columns, column)
              ]
            }
          }
        }
      }
    )

    Outputs = {
      DataTableArn = { Value = { "Fn::GetAtt" = ["VeevaTransferTable", "Arn"] } }
    }
  }

  veeva_transfer_data_table_id = try(element(
    reverse(split("/", aws_cloudformation_stack.veeva_transfer_data_table[0].outputs["DataTableArn"])),
    0
  ), null)
}

resource "aws_cloudformation_stack" "veeva_transfer_data_table" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  name          = "btsgsd-dev-VeevaTransferDataTable"
  template_body = jsonencode(local.veeva_transfer_template)
  parameters = {
    InstanceArn = module.connect_us_east_1[0].instance_arn
  }
  tags = local.common_tags

  lifecycle {
    precondition {
      condition = (
        module.connect_us_east_1[0].instance_arn ==
        "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
      )
      error_message = "The Veeva transfer table must be created in the confirmed Dev Connect instance."
    }

    precondition {
      condition = alltrue([
        for row in values(local.veeva_transfer_rows) :
        trimspace(row.country_LATAM) != "" &&
        can(regex("^\\+[1-9][0-9]{1,14}$", row.system_phonenumber)) &&
        can(regex("^\\+[1-9][0-9]{1,14}$", row.Veeva_contact))
      ])
      error_message = "Veeva rows require a country and E.164 system/transfer phone numbers."
    }
  }
}

output "veeva_transfer_data_table" {
  description = "BTS_GSD-Veeva_Transfer identifiers for lookups using country_LATAM and system_phonenumber."
  value = try({
    name = "BTS_GSD-Veeva_Transfer"
    arn  = aws_cloudformation_stack.veeva_transfer_data_table[0].outputs["DataTableArn"]
    id   = local.veeva_transfer_data_table_id
  }, null)
}

# An empty blocker message is intentional; retain it as an empty TEXT value.
locals {
  top_level_blocker_csv = <<-CSV
"system_phonenumber","toplevelblocker_message"
"'+18335162999",""
CSV

  top_level_blocker_raw_rows = csvdecode(trimspace(local.top_level_blocker_csv))
  top_level_blocker_columns  = keys(local.top_level_blocker_raw_rows[0])
  top_level_blocker_rows = {
    for row in local.top_level_blocker_raw_rows :
    trimprefix(trimspace(row.system_phonenumber), "'") => merge(row, {
      system_phonenumber = trimprefix(trimspace(row.system_phonenumber), "'")
    })
  }

  top_level_blocker_template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Amazon Connect top-level blocker messages by dialed phone number."
    Parameters = {
      InstanceArn = { Type = "String" }
    }

    Resources = merge(
      {
        TopLevelBlockerTable = {
          Type = "AWS::Connect::DataTable"
          Properties = {
            InstanceArn    = { Ref = "InstanceArn" }
            Name           = "TopLevelBlockerMessage"
            Description    = "Top-level blocker message by system phone number."
            Status         = "PUBLISHED"
            TimeZone       = "UTC"
            ValueLockLevel = "NONE"
            Tags = [
              for key, value in merge(local.common_tags, { Name = "TopLevelBlockerMessage" }) : {
                Key   = key
                Value = value
              }
            ]
          }
        }
      },
      {
        for column in local.top_level_blocker_columns : "Attribute${replace(column, "_", "")}" => {
          Type = "AWS::Connect::DataTableAttribute"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["TopLevelBlockerTable", "Arn"] }
            Name         = column
            ValueType    = "TEXT"
            Primary      = column == "system_phonenumber"
          }
        }
      },
      {
        for phone_number, row in local.top_level_blocker_rows : "Record${replace(phone_number, "+", "")}" => {
          Type = "AWS::Connect::DataTableRecord"
          Properties = {
            InstanceArn  = { Ref = "InstanceArn" }
            DataTableArn = { "Fn::GetAtt" = ["TopLevelBlockerTable", "Arn"] }
            DataTableRecord = {
              PrimaryValues = [
                {
                  AttributeId    = { "Fn::GetAtt" = ["Attributesystemphonenumber", "AttributeId"] }
                  AttributeValue = phone_number
                }
              ]
              Values = [
                for column in local.top_level_blocker_columns : {
                  AttributeId    = { "Fn::GetAtt" = ["Attribute${replace(column, "_", "")}", "AttributeId"] }
                  AttributeValue = row[column]
                }
                if column != "system_phonenumber"
              ]
            }
          }
        }
      }
    )

    Outputs = {
      DataTableArn = { Value = { "Fn::GetAtt" = ["TopLevelBlockerTable", "Arn"] } }
    }
  }

  top_level_blocker_data_table_id = try(element(
    reverse(split("/", aws_cloudformation_stack.top_level_blocker_data_table[0].outputs["DataTableArn"])),
    0
  ), null)
}

resource "aws_cloudformation_stack" "top_level_blocker_data_table" {
  count    = local.deploy_connect ? 1 : 0
  provider = aws.us_east_1

  name          = "btsgsd-dev-TopLevelBlockerMessage"
  template_body = jsonencode(local.top_level_blocker_template)
  parameters = {
    InstanceArn = module.connect_us_east_1[0].instance_arn
  }
  tags = local.common_tags

  lifecycle {
    precondition {
      condition = (
        module.connect_us_east_1[0].instance_arn ==
        "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
      )
      error_message = "TopLevelBlockerMessage must be created in the confirmed Dev Connect instance."
    }

    precondition {
      condition = alltrue([
        for phone_number in keys(local.top_level_blocker_rows) :
        can(regex("^\\+[1-9][0-9]{1,14}$", phone_number))
      ])
      error_message = "Top-level blocker system_phonenumber values must use E.164 format."
    }
  }
}

output "top_level_blocker_data_table" {
  description = "TopLevelBlockerMessage identifiers for main inbound flow configuration."
  value = try({
    name = "TopLevelBlockerMessage"
    arn  = aws_cloudformation_stack.top_level_blocker_data_table[0].outputs["DataTableArn"]
    id   = local.top_level_blocker_data_table_id
  }, null)
}
