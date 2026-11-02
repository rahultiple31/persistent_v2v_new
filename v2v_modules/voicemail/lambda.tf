# Six VMX3 functions. Source code is the code currently deployed in the
# voicemail-v2v-* functions; settings are copied from those functions.

locals {
  # Static list so names never depend on other resources.
  function_names = {
    for key in [
      "VoicemailTimestamper",
      "RecordingProcessor",
      "Transcriber",
      "TranscribeErrorHandler",
      "Presigner",
      "Packager",
    ] : key => "${local.prefix}-${key}"
  }

  otel_environment = {
    AWS_LAMBDA_EXEC_WRAPPER = "/opt/otel-instrument"
  }

  functions = {
    VoicemailTimestamper = {
      timeout     = 7
      layers      = [var.otel_layer_arn]
      environment = merge(local.otel_environment, { aws_region = local.region })
    }
    RecordingProcessor = {
      timeout = 300
      layers  = [aws_lambda_layer_version.vmx3.arn]
      environment = {
        aws_region             = local.region
        package_version        = var.package_version
        vmx3_recordings_bucket = aws_s3_bucket.this["recordings"].bucket
      }
    }
    Transcriber = {
      timeout = 848
      layers  = [var.otel_layer_arn]
      environment = merge(local.otel_environment, {
        aws_region            = local.region
        s3_transcripts_bucket = aws_s3_bucket.this["transcripts"].bucket
      })
    }
    TranscribeErrorHandler = {
      timeout = 30
      layers  = [var.otel_layer_arn]
      environment = merge(local.otel_environment, {
        aws_region            = local.region
        s3_transcripts_bucket = aws_s3_bucket.this["transcripts"].bucket
      })
    }
    Presigner = {
      timeout = 330
      layers  = [var.otel_layer_arn]
      environment = merge(local.otel_environment, {
        aws_region       = local.region
        secrets_key_id   = aws_secretsmanager_secret.presigner.arn
        email_url_expire = tostring(var.url_expiration_days)
        tasks_url_expire = tostring(var.url_expiration_days)
      })
    }
    Packager = {
      timeout = 900
      layers  = [var.otel_layer_arn]
      environment = merge(local.otel_environment, {
        aws_region                   = local.region
        package_version              = var.package_version
        TZ                           = var.packager_settings.timezone
        s3_recordings_bucket         = aws_s3_bucket.this["recordings"].bucket
        s3_transcripts_bucket        = aws_s3_bucket.this["transcripts"].bucket
        presigner_function_arn       = local.function_names["Presigner"]
        default_task_flow            = aws_connect_contact_flow.task.contact_flow_id
        default_guided_task_flow     = var.packager_settings.guided_task_flow
        default_vmx_mode             = var.packager_settings.default_vmx_mode
        vmx3_do_genai_summary        = var.packager_settings.do_genai_summary
        inference_model              = var.packager_settings.inference_model
        inference_region             = var.packager_settings.inference_region
        agent_email_key              = var.packager_settings.agent_email_key
        default_email_target         = var.packager_settings.default_email_target
        default_email_from           = var.packager_settings.default_email_from
        default_agent_email_template = var.packager_settings.agent_email_template
        default_queue_email_template = var.packager_settings.queue_email_template
      })
    }
  }
}

# Python dependencies (pydub, audioop-lts, ffmpeg, lxml, phonenumbers),
# copied from VMX3-Python-Layer-btsgsd-dev-us-east-1 version 1.
resource "aws_lambda_layer_version" "vmx3" {
  layer_name          = "${var.name_prefix}-VMX3-Python-Layer"
  description         = "Provides dependencies code and functions for AWS Lambda functions that power Voicemail Express."
  filename            = "${path.module}/layers/vmx3-python-layer.zip"
  source_code_hash    = filebase64sha256("${path.module}/layers/vmx3-python-layer.zip")
  compatible_runtimes = ["python3.13"]
  license_info        = "https://aws.amazon.com/apache-2-0"

  # Keep earlier layer versions when the zip changes.
  skip_destroy = true
}

data "archive_file" "function" {
  for_each = local.functions

  type        = "zip"
  source_dir  = "${path.module}/src/${each.key}"
  output_path = "${path.root}/metadata/voicemail/${each.key}.zip"
}

resource "aws_cloudwatch_log_group" "function" {
  for_each = local.functions

  name              = "/aws/lambda/${local.function_names[each.key]}"
  retention_in_days = var.log_retention_days
  tags              = merge(var.tags, { Name = local.function_names[each.key] })
}

# Deploy the core security group before planning these Lambda settings.
data "aws_security_group" "lambda_core" {
  name   = "BTSGSD-V2V-US-LAMBDA-core-sg"
  vpc_id = "vpc-0f2abb3d6596a0487"
}

resource "aws_lambda_function" "this" {
  for_each = local.functions

  function_name           = local.function_names[each.key]
  role                    = aws_iam_role.lambda.arn
  runtime                 = "python3.13"
  architectures           = ["x86_64"]
  handler                 = "lambda_function.lambda_handler"
  filename                = data.archive_file.function[each.key].output_path
  source_code_hash        = data.archive_file.function[each.key].output_base64sha256
  timeout                 = each.value.timeout
  memory_size             = 128
  layers                  = each.value.layers
  code_signing_config_arn = var.code_signing_config_arn

  vpc_config {
    # VPC: vpc-0f2abb3d6596a0487 (abv-vpc-accas-dev-vpc).
    # Lambda derives the VPC from these subnet IDs.
    subnet_ids = [
      "subnet-0c29b5f2c41c73d89", # us-east-1a: abv-vpc-accas-dev-app-a
      "subnet-0fe7a72e5cef073ad", # us-east-1b: abv-vpc-accas-dev-app-b
    ]

    security_group_ids = [
      "sg-0e77977e08fb0dedb", # BTSGSD-US-IVA-Internal-SG
      data.aws_security_group.lambda_core.id,
    ]

    ipv6_allowed_for_dual_stack = false
  }

  environment {
    variables = each.value.environment
  }

  tracing_config {
    mode = "Active"
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.function[each.key].name
  }

  tags = merge(var.tags, { Name = local.function_names[each.key] })

  depends_on = [time_sleep.role_ready]
}

# RecordingProcessor reads VMX3 contact trace records from the stream.
resource "aws_lambda_event_source_mapping" "recording_processor" {
  function_name                      = aws_lambda_function.this["RecordingProcessor"].arn
  event_source_arn                   = aws_kinesis_stream.ctr.arn
  starting_position                  = "LATEST"
  batch_size                         = 1
  maximum_batching_window_in_seconds = 0
  parallelization_factor             = 1
  bisect_batch_on_function_error     = true
  maximum_retry_attempts             = 3
  maximum_record_age_in_seconds      = -1

  filter_criteria {
    filter {
      pattern = jsonencode({
        data = {
          Attributes = { vmx3_flag = ["1"] }
          Recordings = { ParticipantType = ["IVR"] }
          Agent      = [null]
        }
      })
    }
  }

  depends_on = [time_sleep.role_ready]
}
