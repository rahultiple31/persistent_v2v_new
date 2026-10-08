resource "aws_s3_bucket" "reporting" {
  bucket        = var.bucket_name
  force_destroy = false
  tags          = var.common_tags
}

resource "aws_s3_bucket_public_access_block" "reporting" {
  bucket = aws_s3_bucket.reporting.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "reporting" {
  bucket = aws_s3_bucket.reporting.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reporting" {
  bucket = aws_s3_bucket.reporting.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "reporting" {
  bucket = aws_s3_bucket.reporting.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "reporting" {
  bucket = aws_s3_bucket.reporting.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.reporting.arn,
          "${aws_s3_bucket.reporting.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "reporting" {
  for_each = var.lambda_role_names

  name = "connect-reporting-survey-csv-access"
  role = each.value

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadAmazonConnectSurveyContacts"
        Effect = "Allow"
        Action = [
          "connect:SearchContacts",
          "connect:DescribeContact",
          "connect:GetContactAttributes",
          "connect:DescribeUser",
          "connect:DescribeQueue"
        ]
        Resource = "*"
      },
      {
        Sid    = "WriteSurveyCSVToS3"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:AbortMultipartUpload"
        ]
        Resource = "${aws_s3_bucket.reporting.arn}/connect/daily-interactions/*"
      }
    ]
  })
}
