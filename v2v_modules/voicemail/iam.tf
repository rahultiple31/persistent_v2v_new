# Shared execution role for the six functions, mirroring voicemail-v2v-lambdaRole
# with every reference pointed at the new resources.

locals {
  role_name = "${local.prefix}-lambdaRole"

  # Built from the name to avoid a role -> function -> policy cycle.
  presigner_function_arn = "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${local.function_names["Presigner"]}"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = local.role_name
  description        = "Allows the VMX3 voicemail functions to call AWS services on your behalf."
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = merge(var.tags, { Name = local.role_name })
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid = "connect"
    actions = [
      "connect:DescribeUser",
      "connect:DescribeQueue",
      "connect:GetContactAttributes",
      "connect:UpdateContactAttributes",
      "connect:StartTaskContact",
      "connect:ListUsers",
      "connect:ListUserProficiencies",
      "connect:SearchUsers",
    ]
    resources = [
      var.instance_arn,
      "${var.instance_arn}/queue/*",
      "${var.instance_arn}/user/*",
      "${var.instance_arn}/contact-flow/*",
      "${var.instance_arn}/agent/*",
      "${var.instance_arn}/contact/*",
    ]
  }

  statement {
    sid       = "ses"
    actions   = ["ses:SendEmail", "ses:SendTemplatedEmail"]
    resources = ["*"]
  }

  statement {
    sid       = "transcribe"
    actions   = ["transcribe:DeleteTranscriptionJob", "transcribe:StartTranscriptionJob"]
    resources = ["*"]
  }

  statement {
    sid     = "bedrock"
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = [
      "arn:${local.partition}:bedrock:*::foundation-model/*",
      "arn:${local.partition}:bedrock:*:${local.account_id}:inference-profile/*",
    ]
  }

  statement {
    sid       = "kms"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.voicemail.arn]
  }

  # RecordingProcessor reads the encrypted stream.
  statement {
    sid       = "kmskinesis"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.kinesis.arn]
  }

  statement {
    sid = "kinesis"
    actions = [
      "kinesis:DescribeStream",
      "kinesis:DescribeStreamSummary",
      "kinesis:GetRecords",
      "kinesis:GetShardIterator",
      "kinesis:ListShards",
      "kinesis:ListStreams",
      "kinesis:SubscribeToShard",
    ]
    resources = [aws_kinesis_stream.ctr.arn]
  }

  statement {
    sid       = "secretsmanager"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.presigner.arn]
  }

  statement {
    sid       = "lambda"
    actions   = ["lambda:InvokeFunction"]
    resources = [local.presigner_function_arn]
  }

  statement {
    sid       = "s3buckets"
    actions   = ["s3:ListBucket"]
    resources = [for bucket in aws_s3_bucket.this : bucket.arn]
  }

  statement {
    sid = "s3objects"
    actions = [
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:PutObject",
      "s3:PutObjectTagging",
    ]
    resources = [for bucket in aws_s3_bucket.this : "${bucket.arn}/*"]
  }

  # RecordingProcessor reads the IVR recording written by the instance.
  statement {
    sid       = "connectrecordings"
    actions   = ["s3:GetObject"]
    resources = ["arn:${local.partition}:s3:::${var.connect_recordings_bucket_name}/*"]
  }

  statement {
    sid       = "xray"
    actions   = ["xray:PutTelemetryRecords", "xray:PutTraceSegments"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "lambda" {
  name        = "${local.role_name}_customerManaged"
  description = "Permissions for the ${local.prefix} functions."
  policy      = data.aws_iam_policy_document.lambda.json
  tags        = merge(var.tags, { Name = "${local.role_name}_customerManaged" })
}

resource "aws_iam_role_policy_attachment" "lambda" {
  for_each = {
    custom      = aws_iam_policy.lambda.arn
    basic       = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
    app_signals = "arn:${local.partition}:iam::aws:policy/CloudWatchLambdaApplicationSignalsExecutionRolePolicy"
    vpc_access  = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  }

  role       = aws_iam_role.lambda.name
  policy_arn = each.value
}

# Allow IAM propagation before the functions and the Kinesis mapping are created.
resource "time_sleep" "role_ready" {
  create_duration = "60s"

  depends_on = [aws_iam_role_policy_attachment.lambda]
}
