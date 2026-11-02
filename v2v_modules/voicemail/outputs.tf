output "kms_key_arn" {
  description = "Voicemail KMS key ARN."
  value       = aws_kms_key.voicemail.arn
}

output "kinesis_kms_key_arn" {
  description = "KMS key ARN encrypting the contact trace record stream."
  value       = aws_kms_key.kinesis.arn
}

output "recordings_bucket" {
  description = "Voicemail recordings bucket name."
  value       = aws_s3_bucket.this["recordings"].bucket
}

output "transcripts_bucket" {
  description = "Voicemail transcripts bucket name."
  value       = aws_s3_bucket.this["transcripts"].bucket
}

output "kinesis_stream_arn" {
  description = "Contact trace record stream ARN."
  value       = aws_kinesis_stream.ctr.arn
}

output "secret_arn" {
  description = "Presigner credentials secret ARN."
  value       = aws_secretsmanager_secret.presigner.arn
}

output "lambda_role_arn" {
  description = "Shared execution role ARN."
  value       = aws_iam_role.lambda.arn
}

output "layer_version_arn" {
  description = "VMX3 Python layer version ARN."
  value       = aws_lambda_layer_version.vmx3.arn
}

output "function_arns" {
  description = "Function ARNs keyed by VMX3 component."
  value       = { for key, function in aws_lambda_function.this : key => function.arn }
}

output "timestamper_lambda_arn" {
  description = "Timestamper ARN, associated with the instance."
  value       = aws_connect_lambda_function_association.timestamper.function_arn
}

output "event_rule_arns" {
  description = "EventBridge rule ARNs."
  value       = { for key, rule in aws_cloudwatch_event_rule.this : key => rule.arn }
}

output "task_flow" {
  description = "VMX3 task flow."
  value = {
    name = aws_connect_contact_flow.task.name
    id   = aws_connect_contact_flow.task.contact_flow_id
    arn  = aws_connect_contact_flow.task.arn
  }
}

output "flow_module" {
  description = "VMX3 main voicemail flow module."
  value = {
    name = aws_connect_contact_flow_module.main.name
    id   = aws_connect_contact_flow_module.main.contact_flow_module_id
    arn  = aws_connect_contact_flow_module.main.arn
  }
}
