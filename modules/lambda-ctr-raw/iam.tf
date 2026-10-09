resource "aws_iam_role" "execution" {
  name = "${var.function_name}-lambda-role"
  tags = var.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_access" {
  name = "ctr-raw-lambda-access"
  role = aws_iam_role.execution.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteCloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.raw.arn}:*"
      },
      {
        Sid    = "ReadAmazonConnectContacts"
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
        Sid      = "WriteRawCSVToS3"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "arn:aws:s3:::${var.environment_variables["S3_BUCKET"]}/${trim(var.environment_variables["S3_PREFIX"], "/")}/*"
      }
    ]
  })
}
