################################################################################
# IAM Module
# Creates:
#   • ECS Task Execution Role  (pull from ECR, write CloudWatch logs)
#   • ECS Task Role            (call Bedrock / Transcribe / Translate / Polly /
#                               SSM — never exposed to the browser)
#
# Mirrors CDK: PrivatePocStack > Service > taskDefinition + addToPrincipalPolicy
################################################################################

# ── Shared assume-role policy for ECS tasks ───────────────────────────────────

data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ── Task Execution Role ───────────────────────────────────────────────────────
# Used by the ECS agent to pull the image from ECR and push logs to CloudWatch.

resource "aws_iam_role" "task_execution" {
  name               = "${var.stack_name}-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json

  tags = {
    Name = "${var.stack_name}-task-execution-role"
  }
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:${var.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ── Task Role ─────────────────────────────────────────────────────────────────
# Granted only to running container code; used for all AWS API calls the proxy
# makes at runtime. No credentials ever leave the VPC.

resource "aws_iam_role" "task" {
  name               = "${var.stack_name}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json

  tags = {
    Name = "${var.stack_name}-task-role"
  }
}

# ── Policy 1: Bedrock InvokeModel ─────────────────────────────────────────────

data "aws_iam_policy_document" "bedrock" {
  statement {
    sid     = "InvokeNovaSonic"
    effect  = "Allow"
    actions = ["bedrock:InvokeModel"]

    resources = [
      "arn:${var.partition}:bedrock:${var.ai_region}::foundation-model/${var.nova_sonic_model_id}",
    ]
  }
}

resource "aws_iam_role_policy" "bedrock" {
  name   = "bedrock-invoke"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.bedrock.json
}

# ── Policy 2: Transcribe / Translate / Polly (region-scoped) ─────────────────

data "aws_iam_policy_document" "ai_services" {
  statement {
    sid    = "TranscribeStreaming"
    effect = "Allow"

    actions = ["transcribe:StartStreamTranscription"]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.ai_region]
    }
  }

  statement {
    sid    = "Translate"
    effect = "Allow"

    actions = ["translate:TranslateText"]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.ai_region]
    }
  }

  statement {
    sid    = "Polly"
    effect = "Allow"

    actions = ["polly:SynthesizeSpeech"]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.ai_region]
    }
  }
}

resource "aws_iam_role_policy" "ai_services" {
  name   = "ai-services"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.ai_services.json
}

# ── Policy 3: SSM — forceBackupTranslation parameter ─────────────────────────

data "aws_iam_policy_document" "ssm_force_backup" {
  statement {
    sid     = "ReadForceBackupParameter"
    effect  = "Allow"
    actions = ["ssm:GetParameter"]

    resources = [var.force_backup_parameter_arn]
  }
}

resource "aws_iam_role_policy" "ssm_force_backup" {
  name   = "ssm-force-backup"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.ssm_force_backup.json
}

# ── Policy 4 (optional): SSM — testSignIn SecureString parameter ──────────────
# Only created when test_sign_in = true. The parameter itself is created by
# hand as a SecureString; Terraform only grants read access to it.

data "aws_iam_policy_document" "ssm_test_sign_in" {
  count = var.test_sign_in ? 1 : 0

  statement {
    sid     = "ReadTestSignInParameter"
    effect  = "Allow"
    actions = ["ssm:GetParameter"]

    resources = [var.test_sign_in_parameter_arn]
  }
}

resource "aws_iam_role_policy" "ssm_test_sign_in" {
  count = var.test_sign_in ? 1 : 0

  name   = "ssm-test-sign-in"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.ssm_test_sign_in[0].json
}

# ── Policy 5 (optional): KMS Decrypt for the testSignIn SecureString ──────────
# SSM SecureString parameters are encrypted with a KMS key; the task role must
# be able to call kms:Decrypt scoped to that parameter ARN via the SSM VPC
# endpoint to avoid any cleartext exposure.

data "aws_iam_policy_document" "kms_test_sign_in" {
  count = var.test_sign_in ? 1 : 0

  statement {
    sid     = "DecryptTestSignInKey"
    effect  = "Allow"
    actions = ["kms:Decrypt"]

    # The KMS key ARN is not known at deploy time (it is the default SSM key or
    # a manually created key). Scope to the account's keys and restrict via
    # ViaService + EncryptionContext so no other secret can be decrypted.
    resources = [
      "arn:${var.partition}:kms:${var.aws_region}:${var.account_id}:key/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:PARAMETER_ARN"
      values   = [var.test_sign_in_parameter_arn]
    }
  }
}

resource "aws_iam_role_policy" "kms_test_sign_in" {
  count = var.test_sign_in ? 1 : 0

  name   = "kms-test-sign-in"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.kms_test_sign_in[0].json
}
