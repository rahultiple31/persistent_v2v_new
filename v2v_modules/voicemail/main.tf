# VMX3 voicemail stack for the V2V instance.
# Every resource here is new; the console-built voicemail-v2v* resources are
# left untouched and are deleted manually by the team (see README.md).

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.region
  partition   = data.aws_partition.current.partition
  instance_id = split("/", var.instance_arn)[1]

  # BTSGSD-V2V-US-voicemail-<name>; "v2v" is not repeated.
  prefix = "${var.name_prefix}-voicemail"

  # S3 bucket names must be lowercase.
  recordings_bucket_name  = lower("${var.name_prefix}-voicemail-recording")
  transcripts_bucket_name = lower("${var.name_prefix}-voicemail-transcript")

  kinesis_stream_name = "${var.name_prefix}-voiceMail"
  kms_alias           = "alias/${local.prefix}"

  # "recording" replaces the earlier "recordings" bucket (see retired.tf).
  buckets = {
    recording   = local.recordings_bucket_name
    transcripts = local.transcripts_bucket_name
  }
}

# -----------------------------------------------------------------------------
# KMS key for the buckets
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "EnableIAMUserPermissions"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "voicemail" {
  description             = "${local.prefix} voicemail recordings, transcripts and secret"
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
  tags                    = merge(var.tags, { Name = local.prefix })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "voicemail" {
  name          = local.kms_alias
  target_key_id = aws_kms_key.voicemail.key_id
}

# -----------------------------------------------------------------------------
# S3 buckets (settings copied from voicemail-v2v and voicemail-v2v-transcript)
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "this" {
  for_each = local.buckets

  bucket              = each.value
  object_lock_enabled = true
  force_destroy       = false
  tags                = merge(var.tags, { Name = each.value })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACLs enabled with the owner-only (private) grant, as on the existing buckets.
resource "aws_s3_bucket_acl" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  acl      = "private"

  depends_on = [
    aws_s3_bucket_ownership_controls.this,
    aws_s3_bucket_public_access_block.this,
  ]
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.voicemail.arn
    }
    bucket_key_enabled = true
  }
}

# Object Lock is enabled on the bucket with no default retention (as existing).

resource "aws_s3_bucket_notification" "this" {
  for_each    = aws_s3_bucket.this
  bucket      = each.value.id
  eventbridge = true
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id

  rule {
    id     = "V2VDeletePolicy"
    status = "Enabled"

    filter {}

    expiration {
      days = var.recording_expiration_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

data "aws_iam_policy_document" "bucket" {
  for_each = aws_s3_bucket.this

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [each.value.arn, "${each.value.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  policy   = data.aws_iam_policy_document.bucket[each.key].json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

# -----------------------------------------------------------------------------
# Kinesis data stream (contact trace records; settings from voiceMail-v2v,
# plus server-side encryption with a dedicated customer managed key)
# -----------------------------------------------------------------------------
data "aws_connect_instance" "target" {
  instance_id = local.instance_id
}

# Connect writes records with the instance's service-linked role, which needs
# kms:GenerateDataKey on the stream key. The Lambda role decrypts through IAM.
data "aws_iam_policy_document" "kinesis_kms" {
  statement {
    sid       = "EnableIAMUserPermissions"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowConnectStreaming"
    actions   = ["kms:GenerateDataKey"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_connect_instance.target.service_role]
    }
  }
}

resource "aws_kms_key" "kinesis" {
  description             = "${local.prefix} contact trace record stream"
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kinesis_kms.json
  tags                    = merge(var.tags, { Name = "${local.prefix}-kinesis" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "kinesis" {
  name          = "${local.kms_alias}-kinesis"
  target_key_id = aws_kms_key.kinesis.key_id
}

resource "aws_kinesis_stream" "ctr" {
  name             = local.kinesis_stream_name
  retention_period = 24
  encryption_type  = "KMS"
  kms_key_id       = aws_kms_key.kinesis.arn

  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }

  tags = merge(var.tags, { Name = local.kinesis_stream_name })

  lifecycle {
    prevent_destroy = true
  }
}

# Connect supports one Kinesis stream for contact trace records. Remove the
# console association to voiceMail-v2v before enabling this (see README.md).
resource "aws_connect_instance_storage_config" "ctr" {
  count = var.associate_ctr_stream ? 1 : 0

  instance_id   = local.instance_id
  resource_type = "CONTACT_TRACE_RECORDS"

  storage_config {
    storage_type = "KINESIS_STREAM"

    kinesis_stream_config {
      stream_arn = aws_kinesis_stream.ctr.arn
    }
  }
}

# Agent events go to the same stream. Connect also allows one Kinesis stream
# for agent events: remove the console association to voiceMail-v2v first.
resource "aws_connect_instance_storage_config" "agent_events" {
  count = var.associate_agent_events_stream ? 1 : 0

  instance_id   = local.instance_id
  resource_type = "AGENT_EVENTS"

  storage_config {
    storage_type = "KINESIS_STREAM"

    kinesis_stream_config {
      stream_arn = aws_kinesis_stream.ctr.arn
    }
  }
}

# The presigner access key and its secret (BTSGSD-V2V-US-voicemail) were
# removed: user access keys are not allowed. Terraform deletes both.
