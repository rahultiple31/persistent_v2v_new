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
  recordings_bucket_name  = lower("${var.name_prefix}-voicemail")
  transcripts_bucket_name = lower("${var.name_prefix}-voicemail-transcript")

  kinesis_stream_name = "${var.name_prefix}-voiceMail"
  secret_name         = local.prefix
  kms_alias           = "alias/${local.prefix}"

  presigner_user_arn = data.aws_iam_user.presigner.arn

  presigner_credentials = var.create_presigner_access_key ? {
    access_key_id     = aws_iam_access_key.presigner[0].id
    secret_access_key = aws_iam_access_key.presigner[0].secret
  } : var.presigner_credentials

  buckets = {
    recordings  = local.recordings_bucket_name
    transcripts = local.transcripts_bucket_name
  }
}

# Existing presigner user; read only, never modified by this module.
data "aws_iam_user" "presigner" {
  user_name = var.presigner_user_name
}

# -----------------------------------------------------------------------------
# KMS key for the buckets and the secret
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

  # The presigner user signs GET URLs; the caller downloads through S3.
  statement {
    sid       = "AllowPresignerUserDecryptViaS3"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.presigner_user_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${local.region}.amazonaws.com"]
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

  # Presigned recording URLs are signed by the existing presigner user.
  dynamic "statement" {
    for_each = each.key == "recordings" ? [1] : []

    content {
      sid       = "AllowPresignerUserGetObject"
      actions   = ["s3:GetObject"]
      resources = ["${each.value.arn}/*"]

      principals {
        type        = "AWS"
        identifiers = [local.presigner_user_arn]
      }
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

# -----------------------------------------------------------------------------
# Secret holding the presigner user's access key
# -----------------------------------------------------------------------------
resource "aws_iam_access_key" "presigner" {
  count = var.create_presigner_access_key ? 1 : 0
  user  = data.aws_iam_user.presigner.user_name
}

resource "aws_secretsmanager_secret" "presigner" {
  name                    = local.secret_name
  description             = "Stores user credentials for the presigner function"
  kms_key_id              = aws_kms_key.voicemail.arn
  recovery_window_in_days = 30
  tags                    = merge(var.tags, { Name = local.secret_name })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "presigner" {
  secret_id = aws_secretsmanager_secret.presigner.id
  secret_string = jsonencode({
    vmx_iam_key_id     = local.presigner_credentials.access_key_id
    vmx_iam_key_secret = local.presigner_credentials.secret_access_key
  })

  lifecycle {
    precondition {
      condition     = local.presigner_credentials != null
      error_message = "Set create_presigner_access_key = true or supply presigner_credentials."
    }
  }
}
