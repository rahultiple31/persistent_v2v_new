data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

moved {
  from = aws_s3_bucket.webapp
  to   = aws_s3_bucket.v2v
}

moved {
  from = aws_s3_bucket.webapp_logs
  to   = aws_s3_bucket.v2v_logs
}

moved {
  from = aws_s3_bucket_public_access_block.webapp
  to   = aws_s3_bucket_public_access_block.v2v
}

moved {
  from = aws_s3_bucket_public_access_block.webapp_logs
  to   = aws_s3_bucket_public_access_block.v2v_logs
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.webapp
  to   = aws_s3_bucket_server_side_encryption_configuration.v2v
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.webapp_logs
  to   = aws_s3_bucket_server_side_encryption_configuration.v2v_logs
}

moved {
  from = aws_s3_bucket_versioning.webapp
  to   = aws_s3_bucket_versioning.v2v
}

moved {
  from = aws_s3_bucket_versioning.webapp_logs
  to   = aws_s3_bucket_versioning.v2v_logs
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.webapp
  to   = aws_s3_bucket_lifecycle_configuration.v2v
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.webapp_logs
  to   = aws_s3_bucket_lifecycle_configuration.v2v_logs
}

moved {
  from = aws_s3_bucket_ownership_controls.webapp_logs
  to   = aws_s3_bucket_ownership_controls.v2v_logs
}

moved {
  from = aws_s3_bucket_acl.webapp_logs
  to   = aws_s3_bucket_acl.v2v_logs
}

moved {
  from = aws_s3_bucket_policy.webapp
  to   = aws_s3_bucket_policy.v2v
}

moved {
  from = aws_s3_bucket_policy.webapp_logs
  to   = aws_s3_bucket_policy.v2v_logs
}

moved {
  from = aws_s3_object.webapp_assets
  to   = aws_s3_object.v2v_assets
}

locals {
  app_name_lower       = lower(replace(var.app_name, "_", "-"))
  v2v_root             = trimsuffix(var.v2v_root_prefix, "/")
  v2v_object_prefix    = local.v2v_root == "" ? "" : "${local.v2v_root}/"
  v2v_dist_path        = var.v2v_dist_path == null ? abspath("${path.root}/../../webapp/dist") : abspath(var.v2v_dist_path)
  v2v_files            = var.deploy_v2v_assets ? try(fileset(local.v2v_dist_path, "**"), toset([])) : toset([])

  content_types = {
    css   = "text/css"
    gif   = "image/gif"
    html  = "text/html"
    ico   = "image/x-icon"
    jpeg  = "image/jpeg"
    jpg   = "image/jpeg"
    js    = "text/javascript"
    json  = "application/json"
    map   = "application/json"
    mp3   = "audio/mpeg"
    png   = "image/png"
    svg   = "image/svg+xml"
    txt   = "text/plain"
    wav   = "audio/wav"
    webp  = "image/webp"
    woff  = "font/woff"
    woff2 = "font/woff2"
  }
}

resource "aws_s3_bucket" "v2v" {
  bucket        = "${local.app_name_lower}-v2vbucket-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
  force_destroy = var.force_destroy_buckets
  tags          = var.common_tags
}

resource "aws_s3_bucket" "v2v_logs" {
  bucket        = "${local.app_name_lower}-v2vlogbucket-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
  force_destroy = var.force_destroy_buckets
  tags          = var.common_tags
}

resource "aws_s3_bucket_public_access_block" "v2v" {
  bucket = aws_s3_bucket.v2v.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "v2v_logs" {
  bucket = aws_s3_bucket.v2v_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "v2v" {
  bucket = aws_s3_bucket.v2v.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "v2v_logs" {
  bucket = aws_s3_bucket.v2v_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "v2v" {
  bucket = aws_s3_bucket.v2v.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "v2v_logs" {
  bucket = aws_s3_bucket.v2v_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "v2v" {
  bucket = aws_s3_bucket.v2v.id

  rule {
    id     = "expire-noncurrent-v2v-assets"
    status = "Enabled"

    filter {
      prefix = local.v2v_object_prefix
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "v2v_logs" {
  bucket = aws_s3_bucket.v2v_logs.id

  rule {
    id     = "expire-cloudfront-logs"
    status = "Enabled"

    filter {
      prefix = "cloudfront-logs/"
    }

    expiration {
      days = var.log_expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_log_version_expiration_days
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "v2v_logs" {
  bucket = aws_s3_bucket.v2v_logs.id

  rule {
    object_ownership = "ObjectWriter"
  }
}

resource "aws_s3_bucket_acl" "v2v_logs" {
  bucket = aws_s3_bucket.v2v_logs.id
  acl    = "log-delivery-write"

  depends_on = [
    aws_s3_bucket_ownership_controls.v2v_logs,
    aws_s3_bucket_public_access_block.v2v_logs
  ]
}

data "aws_iam_policy_document" "v2v_bucket" {
  statement {
    sid     = "AllowCloudFrontServicePrincipalReadOnly"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    resources = ["${aws_s3_bucket.v2v.arn}/${local.v2v_object_prefix}*"]
  }

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.v2v.arn,
      "${aws_s3_bucket.v2v.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

data "aws_iam_policy_document" "v2v_logs_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.v2v_logs.arn,
      "${aws_s3_bucket.v2v_logs.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "v2v" {
  bucket = aws_s3_bucket.v2v.id
  policy = data.aws_iam_policy_document.v2v_bucket.json
}

resource "aws_s3_bucket_policy" "v2v_logs" {
  bucket = aws_s3_bucket.v2v_logs.id
  policy = data.aws_iam_policy_document.v2v_logs_bucket.json
}

resource "aws_s3_object" "frontend_config" {
  bucket       = aws_s3_bucket.v2v.id
  key          = "${local.v2v_object_prefix}frontend-config.js"
  content      = "window.V2VConfig = ${jsonencode(var.frontend_config)}"
  content_type = "text/javascript"
  etag         = md5("window.V2VConfig = ${jsonencode(var.frontend_config)}")
  tags         = var.common_tags
}

resource "aws_s3_object" "v2v_assets" {
  for_each = {
    for file_path in local.v2v_files : file_path => file_path
    if !endswith(file_path, "/")
  }

  bucket       = aws_s3_bucket.v2v.id
  key          = "${local.v2v_object_prefix}${each.value}"
  source       = "${local.v2v_dist_path}/${each.value}"
  content_type = lookup(local.content_types, lower(element(reverse(split(".", each.value)), 0)), "binary/octet-stream")
  etag         = filemd5("${local.v2v_dist_path}/${each.value}")
  tags         = var.common_tags
}
