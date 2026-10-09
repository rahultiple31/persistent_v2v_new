resource "aws_iam_role" "execution" {
  for_each = {
    lambda    = "lambda.amazonaws.com"
    scheduler = "scheduler.amazonaws.com"
  }

  name = "${var.function_name}-${each.key}-role"
  tags = var.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = each.value }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_access" {
  name = "ctr-survey-lambda-access"
  role = aws_iam_role.execution["lambda"].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteCloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.survey.arn}:*"
      },
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
        Sid      = "WriteSurveyCSVToS3"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "arn:aws:s3:::${var.environment_variables["S3_BUCKET"]}/${trim(var.environment_variables["S3_PREFIX"], "/")}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  name = "ctr-survey-scheduler-invoke"
  role = aws_iam_role.execution["scheduler"].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["lambda:InvokeFunction"]
      Resource = aws_lambda_function.survey.arn
    }]
  })
}
