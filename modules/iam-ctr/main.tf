resource "aws_iam_policy" "ctr" {
  name = var.policy_name

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
        Sid      = "WriteSurveyCSVToS3"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = var.s3_object_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ctr" {
  for_each = var.role_names

  role       = each.value
  policy_arn = aws_iam_policy.ctr.arn
}
