# This module receives var.bucket_name from its parent.
# It does not declare aws_s3_bucket.this.
# Define this policy resource only once within the module.

data "aws_partition" "current" {}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.bucket_name}",
      "arn:${data.aws_partition.current.partition}:s3:::${var.bucket_name}/*",
    ]

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
  bucket = var.bucket_name
  policy = data.aws_iam_policy_document.bucket.json
}
