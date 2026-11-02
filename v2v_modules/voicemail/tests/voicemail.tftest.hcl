# Plan-only: prevent_destroy blocks the cleanup an apply test would need.
mock_provider "aws" {
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "518902362956" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-1" }
  }
  override_data {
    target = data.aws_partition.current
    values = { partition = "aws" }
  }
  override_data {
    target = data.aws_iam_user.presigner
    values = {
      arn       = "arn:aws:iam::518902362956:user/VMX3_Presigner_User_btsgsd-dev-us-east-1"
      user_name = "VMX3_Presigner_User_btsgsd-dev-us-east-1"
    }
  }
  override_data {
    target = data.aws_connect_contact_flow.customer_queue
    values = {
      arn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e/contact-flow/5a91146a-e655-4e69-98e9-c0f54c3e38e1"
    }
  }
}

override_data {
  target = data.aws_iam_policy_document.kms
  values = { json = "{}" }
}

override_data {
  target = data.aws_iam_policy_document.kinesis_kms
  values = { json = "{}" }
}

override_data {
  target = data.aws_connect_instance.target
  values = {
    service_role = "arn:aws:iam::518902362956:role/aws-service-role/connect.amazonaws.com/AWSServiceRoleForAmazonConnect_KB2hUzhYjcRlHoTddMFU"
  }
}

override_data {
  target = data.aws_iam_policy_document.lambda_assume
  values = { json = "{}" }
}

override_data {
  target = data.aws_iam_policy_document.lambda
  values = { json = "{}" }
}

override_data {
  target = data.aws_iam_policy_document.bucket
  values = { json = "{}" }
}

mock_provider "time" {}

variables {
  instance_arn                   = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
  voicemail_queue_arn            = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e/queue/257cafaf-87c4-4e32-9f0b-3fbb8b942433"
  beep_prompt_arn                = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e/prompt/ccf6f51f-b39a-4ccd-aa65-80349b07bf65"
  prompt_data_table_id           = "72ee5d56-a0e3-4001-8330-de88345a001f"
  connect_recordings_bucket_name = "amazon-connect-e9a2e832a017"
}

run "names_follow_convention" {
  command = plan

  assert {
    condition = (
      aws_s3_bucket.this["recordings"].bucket == "btsgsd-v2v-us-voicemail" &&
      aws_s3_bucket.this["transcripts"].bucket == "btsgsd-v2v-us-voicemail-transcript" &&
      aws_kinesis_stream.ctr.name == "BTSGSD-V2V-US-voiceMail" &&
      aws_secretsmanager_secret.presigner.name == "BTSGSD-V2V-US-voicemail" &&
      aws_iam_role.lambda.name == "BTSGSD-V2V-US-voicemail-lambdaRole" &&
      aws_lambda_layer_version.vmx3.layer_name == "BTSGSD-V2V-US-VMX3-Python-Layer" &&
      aws_kms_alias.voicemail.name == "alias/BTSGSD-V2V-US-voicemail" &&
      aws_connect_contact_flow.task.name == "BTSGSD-V2V-US-VMX3_Basic_Task_Flow" &&
      aws_connect_contact_flow_module.main.name == "BTSGSD-V2V-US-VMX3_Main_VM_Module"
    )
    error_message = "Resource names must follow BTSGSD-V2V-US-<name>."
  }

  assert {
    condition = toset([for f in aws_lambda_function.this : f.function_name]) == toset([
      "BTSGSD-V2V-US-voicemail-VoicemailTimestamper",
      "BTSGSD-V2V-US-voicemail-RecordingProcessor",
      "BTSGSD-V2V-US-voicemail-Transcriber",
      "BTSGSD-V2V-US-voicemail-TranscribeErrorHandler",
      "BTSGSD-V2V-US-voicemail-Presigner",
      "BTSGSD-V2V-US-voicemail-Packager",
    ])
    error_message = "All six functions must be created with the new names."
  }

  assert {
    condition = toset([for r in aws_cloudwatch_event_rule.this : r.name]) == toset([
      "BTSGSD-V2V-US-voicemail-PackagerRule",
      "BTSGSD-V2V-US-voicemail-TranscriberRule",
      "BTSGSD-V2V-US-voicemail-TranscribeErrorHandlerRule",
    ])
    error_message = "All three EventBridge rules must be created with the new names."
  }
}

run "buckets_match_existing_configuration" {
  command = plan

  assert {
    condition = alltrue([
      for key in ["recordings", "transcripts"] :
      aws_s3_bucket.this[key].object_lock_enabled &&
      aws_s3_bucket_ownership_controls.this[key].rule[0].object_ownership == "BucketOwnerPreferred" &&
      aws_s3_bucket_acl.this[key].acl == "private" &&
      aws_s3_bucket_versioning.this[key].versioning_configuration[0].status == "Enabled" &&
      aws_s3_bucket_public_access_block.this[key].block_public_acls &&
      aws_s3_bucket_public_access_block.this[key].block_public_policy &&
      aws_s3_bucket_public_access_block.this[key].ignore_public_acls &&
      aws_s3_bucket_public_access_block.this[key].restrict_public_buckets &&
      one(aws_s3_bucket_server_side_encryption_configuration.this[key].rule).bucket_key_enabled &&
      one(one(aws_s3_bucket_server_side_encryption_configuration.this[key].rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms" &&
      aws_s3_bucket_notification.this[key].eventbridge &&
      aws_s3_bucket_lifecycle_configuration.this[key].rule[0].id == "V2VDeletePolicy" &&
      aws_s3_bucket_lifecycle_configuration.this[key].rule[0].status == "Enabled" &&
      aws_s3_bucket_lifecycle_configuration.this[key].rule[0].expiration[0].days == 7
    ])
    error_message = "Both buckets must match the existing voicemail-v2v bucket settings."
  }
}

run "flows_reference_only_the_target_instance" {
  command = plan

  assert {
    condition = (
      !strcontains(aws_connect_contact_flow_module.main.content, "c227a737-3e4f-4c64-8397-2d37e318801d") &&
      !strcontains(aws_connect_contact_flow_module.main.content, "abbvie-sd-contactcenter") &&
      !strcontains(aws_connect_contact_flow_module.main.content, "0c2359aa-9062-43ec-9d0d-abc5861c2197") &&
      !strcontains(aws_connect_contact_flow.task.content, "c227a737-3e4f-4c64-8397-2d37e318801d")
    )
    error_message = "No SSO-instance reference may remain."
  }

  assert {
    condition = (
      one([for a in jsondecode(aws_connect_contact_flow_module.main.content).Actions : a if a.Type == "UpdateContactTargetQueue"]).Parameters.QueueId == var.voicemail_queue_arn &&
      one([for a in jsondecode(aws_connect_contact_flow_module.main.content).Actions : a if a.Identifier == "voicemail attributes"]).Parameters.Attributes.vmx3_queue_arn == var.voicemail_queue_arn &&
      one([for a in jsondecode(aws_connect_contact_flow_module.main.content).Actions : a if a.Identifier == "Play the start recording beep using SSML"]).Parameters.PromptId == var.beep_prompt_arn &&
      one([for a in jsondecode(aws_connect_contact_flow_module.main.content).Actions : a if a.Type == "EvaluateDataTableValues"]).Parameters.DataTableId == var.prompt_data_table_id &&
      one([for a in jsondecode(aws_connect_contact_flow_module.main.content).Actions : a if a.Identifier == "Set Timestamp Function"]).Parameters.FlowAttributes.vmx3_timestamper_function.Value == "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-voicemail-VoicemailTimestamper" &&
      length(jsondecode(aws_connect_contact_flow_module.main.content).Actions) == length(jsondecode(file("${path.module}/assets/VMX3_Main_VM_Module.json")).Actions)
    )
    error_message = "The flow module must point at the target queue, prompt, data table and new timestamper."
  }

  assert {
    condition     = one([for a in jsondecode(aws_connect_contact_flow.task.content).Actions : a if a.Type == "UpdateContactEventHooks"]).Parameters.EventHooks.CustomerQueue == "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e/contact-flow/5a91146a-e655-4e69-98e9-c0f54c3e38e1"
    error_message = "The task flow must use the target instance's customer queue flow."
  }
}

run "kinesis_stream_is_encrypted" {
  command = plan

  assert {
    condition = (
      aws_kinesis_stream.ctr.encryption_type == "KMS" &&
      aws_kms_alias.kinesis.name == "alias/BTSGSD-V2V-US-voicemail-kinesis" &&
      one(aws_kinesis_stream.ctr.stream_mode_details).stream_mode == "ON_DEMAND" &&
      aws_kinesis_stream.ctr.retention_period == 24
    )
    error_message = "The stream must be on-demand, 24 h retention, encrypted with its own key."
  }
}

run "ctr_association_is_opt_in" {
  command = plan

  assert {
    condition     = length(aws_connect_instance_storage_config.ctr) == 0
    error_message = "The CTR stream association must stay off by default."
  }
}

run "ctr_association_when_enabled" {
  command = plan

  variables {
    associate_ctr_stream = true
  }

  assert {
    condition = (
      aws_connect_instance_storage_config.ctr[0].resource_type == "CONTACT_TRACE_RECORDS" &&
      aws_connect_instance_storage_config.ctr[0].instance_id == "bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    )
    error_message = "Enabling the association must stream CTRs from the target instance."
  }
}
