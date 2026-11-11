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
    target = data.aws_connect_contact_flow.customer_queue
    values = {
      arn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e/contact-flow/5a91146a-e655-4e69-98e9-c0f54c3e38e1"
    }
  }
  override_data {
    target = data.aws_security_group.lambda_core
    values = { id = "sg-00000000000000000" }
  }
  override_resource {
    target          = aws_connect_contact_flow.guided_task
    override_during = plan
    values = {
      arn             = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e/contact-flow/99999999-9999-4999-8999-999999999999"
      contact_flow_id = "99999999-9999-4999-8999-999999999999"
    }
  }
  override_resource {
    target          = aws_connect_contact_flow.task
    override_during = plan
    values = {
      contact_flow_id = "88888888-8888-4888-8888-888888888888"
    }
  }
}

mock_provider "awscc" {
  override_resource {
    target          = awscc_connect_view.task
    override_during = plan
    values = {
      view_arn = "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e/view/77777777-7777-4777-8777-777777777777"
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
      aws_s3_bucket.this["recording"].bucket == "btsgsd-v2v-us-voicemail-recording" &&
      aws_s3_bucket.this["transcripts"].bucket == "btsgsd-v2v-us-voicemail-transcript" &&
      aws_kinesis_stream.ctr.name == "BTSGSD-V2V-US-voiceMail" &&
      aws_iam_role.lambda.name == "BTSGSD-V2V-US-voicemail-lambdaRole" &&
      aws_lambda_layer_version.vmx3.layer_name == "BTSGSD-V2V-US-VMX3-Python-Layer" &&
      aws_kms_alias.voicemail.name == "alias/BTSGSD-V2V-US-voicemail" &&
      aws_connect_contact_flow.task.name == "BTSGSD-V2V-US-VMX3_Basic_Task_Flow" &&
      aws_connect_contact_flow.guided_task.name == "BTSGSD-V2V-US-VMX3_Guided_Task_Flow" &&
      awscc_connect_view.task.name == "BTSGSD-V2V-US-Voicemail Task View" &&
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
      "BTSGSD-V2V-US-voicemail-GuidedTaskPresigner",
      "BTSGSD-V2V-US-voicemail-Packager",
    ])
    error_message = "The six functions must include GuidedTaskPresigner and not the user-key Presigner."
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
      for key in ["recording", "transcripts"] :
      aws_s3_bucket.this[key].object_lock_enabled &&
      !aws_s3_bucket.this[key].force_destroy &&
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

run "retired_recordings_bucket_is_kept_with_force_destroy_in_run_a" {
  command = plan

  assert {
    condition = (
      length(aws_s3_bucket.retired_recordings) == 1 &&
      aws_s3_bucket.retired_recordings[0].bucket == "btsgsd-v2v-us-voicemail" &&
      aws_s3_bucket.retired_recordings[0].force_destroy
    )
    error_message = "Run A must keep the old bucket with force_destroy = true."
  }
}

run "retired_recordings_bucket_is_removed_in_run_b" {
  command = plan

  variables {
    delete_retired_recordings_bucket = true
  }

  assert {
    condition     = length(aws_s3_bucket.retired_recordings) == 0
    error_message = "Run B must remove the old bucket."
  }
}

run "guided_task_lambdas_use_no_user_keys" {
  command = plan

  assert {
    condition = (
      aws_lambda_function.this["Packager"].environment[0].variables["default_vmx_mode"] == "guided_task" &&
      aws_lambda_function.this["Packager"].environment[0].variables["default_guided_task_flow"] == "88888888-8888-4888-8888-888888888888" &&
      aws_lambda_function.this["Packager"].environment[0].variables["default_task_flow"] == "AWS::NoValue" &&
      aws_lambda_function.this["Packager"].environment[0].variables["presigner_function_arn"] == "AWS::NoValue" &&
      aws_lambda_function.this["Packager"].environment[0].variables["s3_recordings_bucket"] == "btsgsd-v2v-us-voicemail-recording" &&
      aws_lambda_function.this["RecordingProcessor"].environment[0].variables["vmx3_recordings_bucket"] == "btsgsd-v2v-us-voicemail-recording" &&
      aws_lambda_function.this["GuidedTaskPresigner"].environment[0].variables["s3_recordings_bucket"] == "btsgsd-v2v-us-voicemail-recording" &&
      aws_lambda_function.this["GuidedTaskPresigner"].timeout == 7 &&
      !contains(keys(aws_lambda_function.this), "Presigner")
    )
    error_message = "The Packager must use guided tasks without a presigner, and every function must use the new recordings bucket."
  }

  assert {
    condition = (
      aws_lambda_permission.connect_guided_presigner.principal == "connect.amazonaws.com" &&
      aws_lambda_permission.connect_guided_presigner.source_arn == var.instance_arn &&
      aws_lambda_permission.connect_guided_presigner.function_name == "BTSGSD-V2V-US-voicemail-GuidedTaskPresigner" &&
      aws_connect_lambda_function_association.guided_presigner.instance_id == "bcc989e5-cd9d-494f-9cd4-434f39ccc90e"
    )
    error_message = "The guided presigner must be invocable by, and associated with, the target instance."
  }
}

run "flows_reference_only_the_target_instance" {
  command = plan

  assert {
    condition = alltrue([
      for content in [
        aws_connect_contact_flow_module.main.content,
        aws_connect_contact_flow.task.content,
        aws_connect_contact_flow.guided_task.content,
      ] :
      !strcontains(content, "c227a737-3e4f-4c64-8397-2d37e318801d") &&
      !strcontains(content, "abbvie-sd-contactcenter") &&
      !strcontains(content, "btsgsd-dev-us-east-1") &&
      !strcontains(content, "0c2359aa-9062-43ec-9d0d-abc5861c2197")
    ])
    error_message = "No DEV-SSO reference may remain in the module or flows."
  }

  assert {
    condition = (
      length([for a in jsondecode(aws_connect_contact_flow_module.main.content).Actions : a if a.Type == "UpdateContactTargetQueue"]) == 0 &&
      one([for a in jsondecode(aws_connect_contact_flow_module.main.content).Actions : a if a.Identifier == "voicemail attributes"]).Parameters.Attributes.vmx3_queue_arn == var.voicemail_queue_arn &&
      one([for a in jsondecode(aws_connect_contact_flow_module.main.content).Actions : a if a.Identifier == "voicemail attributes"]).Parameters.Attributes.vmx3_mode == "guided_task" &&
      one([for a in jsondecode(aws_connect_contact_flow_module.main.content).Actions : a if a.Identifier == "Play the start recording beep using SSML"]).Parameters.PromptId == var.beep_prompt_arn &&
      one([for a in jsondecode(aws_connect_contact_flow_module.main.content).Actions : a if a.Type == "EvaluateDataTableValues"]).Parameters.DataTableId == var.prompt_data_table_id &&
      one([for a in jsondecode(aws_connect_contact_flow_module.main.content).Actions : a if a.Identifier == "Set Timestamp Function"]).Parameters.FlowAttributes.vmx3_timestamper_function.Value == "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-voicemail-VoicemailTimestamper" &&
      length(jsondecode(aws_connect_contact_flow_module.main.content).Actions) == length(jsondecode(file("${path.module}/assets/VMX3_Main_VM_Module.json")).Actions)
    )
    error_message = "The flow module must match the latest DEV-SSO export with V2V queue, prompt, data table and timestamper."
  }

  assert {
    condition = (
      one([for a in jsondecode(aws_connect_contact_flow.task.content).Actions : a if a.Type == "UpdateContactEventHooks" && can(a.Parameters.EventHooks.CustomerQueue)]).Parameters.EventHooks.CustomerQueue == "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e/contact-flow/5a91146a-e655-4e69-98e9-c0f54c3e38e1" &&
      one([for a in jsondecode(aws_connect_contact_flow.task.content).Actions : a if a.Type == "UpdateContactEventHooks" && can(a.Parameters.EventHooks.DefaultAgentUI)]).Parameters.EventHooks.DefaultAgentUI == "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e/contact-flow/99999999-9999-4999-8999-999999999999"
    )
    error_message = "The task flow must use the V2V customer queue flow and open the new guided task flow."
  }

  assert {
    condition = (
      one([for a in jsondecode(aws_connect_contact_flow.guided_task.content).Actions : a if a.Type == "ShowView"]).Parameters.ViewResource.Id == "arn:aws:connect:us-east-1:518902362956:instance/bcc989e5-cd9d-494f-9cd4-434f39ccc90e/view/77777777-7777-4777-8777-777777777777:$LATEST" &&
      one([for a in jsondecode(aws_connect_contact_flow.guided_task.content).Actions : a if a.Identifier == "Set Presigner ARN"]).Parameters.FlowAttributes.vmx3_presigner_arn.Value == "arn:aws:lambda:us-east-1:518902362956:function:BTSGSD-V2V-US-voicemail-GuidedTaskPresigner" &&
      jsondecode(aws_connect_contact_flow.guided_task.content).Metadata.ActionMetadata["Show VMX Guided Task view"].parameters.ViewResource.Id.displayName == "BTSGSD-V2V-US-Voicemail Task View"
    )
    error_message = "The guided task flow must show the new view and call the new guided presigner."
  }

  assert {
    condition     = jsondecode(awscc_connect_view.task.template) == jsondecode(file("${path.module}/assets/Voicemail_Task_View.json")).Template
    error_message = "The view template must match the DEV-SSO export."
  }

  assert {
    condition     = length(awscc_connect_view.task.actions) > 0
    error_message = "Cloud Control requires at least one view action."
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

run "agent_events_association_is_opt_in_and_uses_the_stream" {
  command = plan

  assert {
    condition     = length(aws_connect_instance_storage_config.agent_events) == 0
    error_message = "The agent events association must stay off by default."
  }
}

run "agent_events_association_when_enabled" {
  command = plan

  variables {
    associate_agent_events_stream = true
  }

  assert {
    condition = (
      aws_connect_instance_storage_config.agent_events[0].resource_type == "AGENT_EVENTS" &&
      aws_connect_instance_storage_config.agent_events[0].instance_id == "bcc989e5-cd9d-494f-9cd4-434f39ccc90e" &&
      one(aws_connect_instance_storage_config.agent_events[0].storage_config).storage_type == "KINESIS_STREAM"
    )
    error_message = "Enabling the association must stream agent events from the target instance to Kinesis."
  }
}

run "s3_invoke_permissions_use_module_buckets" {
  command = plan

  # Bucket ARNs are computed; pin them during plan to check source_arn.
  override_resource {
    target          = aws_s3_bucket.this["transcripts"]
    override_during = plan
    values = {
      arn = "arn:aws:s3:::btsgsd-v2v-us-voicemail-transcript"
    }
  }

  override_resource {
    target          = aws_s3_bucket.this["recording"]
    override_during = plan
    values = {
      arn = "arn:aws:s3:::btsgsd-v2v-us-voicemail-recording"
    }
  }

  assert {
    condition = (
      aws_lambda_permission.s3["Transcriber"].statement_id == "AllowS3-TranscriptBucket" &&
      aws_lambda_permission.s3["Transcriber"].function_name == "BTSGSD-V2V-US-voicemail-Transcriber" &&
      aws_lambda_permission.s3["Transcriber"].principal == "s3.amazonaws.com" &&
      aws_lambda_permission.s3["Transcriber"].source_account == "518902362956" &&
      aws_lambda_permission.s3["Packager"].statement_id == "AllowS3-TranscriptBucket" &&
      aws_lambda_permission.s3["Packager"].function_name == "BTSGSD-V2V-US-voicemail-Packager" &&
      aws_lambda_permission.s3["Packager"].source_account == "518902362956" &&
      length(aws_lambda_permission.s3) == 2 &&
      aws_lambda_permission.s3["Transcriber"].source_arn == "arn:aws:s3:::btsgsd-v2v-us-voicemail-transcript" &&
      aws_lambda_permission.s3["Packager"].source_arn == "arn:aws:s3:::btsgsd-v2v-us-voicemail-transcript"
    )
    error_message = "Transcriber and Packager must both allow the transcript bucket, in this account."
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
