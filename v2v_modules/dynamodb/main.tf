resource "aws_dynamodb_table" "this" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "callId"
  table_class  = "STANDARD"

  attribute {
    name = "callId"
    type = "S"
  }

  point_in_time_recovery {
    enabled                 = true
    recovery_period_in_days = 35
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  stream_enabled = false

  # Use the supplied customer managed key; null retains the AWS-owned key.
  server_side_encryption {
    enabled     = var.kms_key_arn != null
    kms_key_arn = var.kms_key_arn
  }

  deletion_protection_enabled = false

  tags = {}
}
