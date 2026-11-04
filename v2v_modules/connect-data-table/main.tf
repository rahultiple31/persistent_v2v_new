locals {
  config = jsondecode(
    file("${path.module}/assets/${var.profile}/config.json")
  )

  csv_rows = csvdecode(
    trimprefix(
      file("${path.module}/assets/${var.profile}/data.csv"),
      "\uFEFF"
    )
  )

  columns = keys(local.csv_rows[0])

  normalized_rows = [
    for row in local.csv_rows : {
      for column, value in row : column => (
        contains(local.config.phone_columns, column)
        ? trimprefix(trimspace(value), "'")
        : replace(
          replace(
            replace(
              replace(
                value,
                "interpret-as=“telephone”",
                "interpret-as=\"telephone\""
              ),
              "interpret-as=“ordinal”",
              "interpret-as=\"ordinal\""
            ),
            "<break time = ‘0,2 s’/>",
            "<break time=\"0.2s\"/>"
          ),
          "<break time = ‘0,2s’/>",
          "<break time=\"0.2s\"/>"
        )
      )
    }
  ]

  rows = {
    for row in local.normalized_rows :
    (
      local.config.hashed_record_ids
      ? jsonencode([for column in local.config.primary_columns : row[column]])
      : row[local.config.primary_columns[0]]
    ) => row
  }

  template = {
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = local.config.template_description

    Parameters = {
      InstanceArn = { Type = "String" }
    }

    Resources = merge(
      {
        (local.config.logical_id) = {
          Type = "AWS::Connect::DataTable"
          Properties = {
            InstanceArn    = { Ref = "InstanceArn" }
            Name           = local.config.name
            Description    = local.config.description
            Status         = "PUBLISHED"
            TimeZone       = "UTC"
            ValueLockLevel = "NONE"

            Tags = [
              for key, value in merge(var.tags, { Name = local.config.name }) : {
                Key   = key
                Value = value
              }
            ]
          }
        }
      },
      {
        for column in local.columns :
        "Attribute${replace(column, "_", "")}" => {
          Type = "AWS::Connect::DataTableAttribute"
          Properties = {
            InstanceArn = { Ref = "InstanceArn" }
            DataTableArn = {
              "Fn::GetAtt" = [local.config.logical_id, "Arn"]
            }
            Name      = column
            ValueType = "TEXT"
            Primary   = contains(local.config.primary_columns, column)
          }
        }
      },
      {
        for key, row in local.rows :
        "Record${local.config.hashed_record_ids ? md5(key) : replace(key, "-", "")}" => {
          Type = "AWS::Connect::DataTableRecord"
          Properties = {
            InstanceArn = { Ref = "InstanceArn" }
            DataTableArn = {
              "Fn::GetAtt" = [local.config.logical_id, "Arn"]
            }

            DataTableRecord = {
              PrimaryValues = [
                for column in local.config.primary_columns : {
                  AttributeId = {
                    "Fn::GetAtt" = [
                      "Attribute${replace(column, "_", "")}",
                      "AttributeId"
                    ]
                  }
                  AttributeValue = row[column]
                }
              ]

              Values = [
                for column in local.columns : {
                  AttributeId = {
                    "Fn::GetAtt" = [
                      "Attribute${replace(column, "_", "")}",
                      "AttributeId"
                    ]
                  }
                  AttributeValue = row[column]
                }
                if !contains(local.config.primary_columns, column)
              ]
            }
          }
        }
      }
    )

    Outputs = {
      DataTableArn = {
        Value = {
          "Fn::GetAtt" = [local.config.logical_id, "Arn"]
        }
      }
    }
  }

  template_json = jsonencode(local.template)
}

resource "aws_s3_object" "template" {
  count = local.config.use_s3 ? 1 : 0

  bucket                 = try(var.template_bucket.name, null)
  key                    = "data-tables/prompt/${sha256(local.template_json)}.json"
  content                = local.template_json
  content_type           = "application/json"
  server_side_encryption = "AES256"
  tags                   = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudformation_stack" "this" {
  name = local.config.stack_name

  template_body = local.config.use_s3 ? null : local.template_json
  template_url = local.config.use_s3 ? (
    "https://${var.template_bucket.regional_domain_name}/${aws_s3_object.template[0].key}"
  ) : null

  parameters = {
    InstanceArn = var.connect_instance_arn
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition = (
        length(local.columns) == local.config.expected_columns &&
        length(local.rows) == local.config.expected_rows
      )
      error_message = "The CSV column or record count does not match the table configuration."
    }

    precondition {
      condition = var.profile != "prompt" ? true : (
        toset(keys(local.rows)) == toset(["en-US", "es-MX", "pt-BR"])
      )
      error_message = "The prompt CSV must contain en-US, es-MX and pt-BR."
    }
  }
}
