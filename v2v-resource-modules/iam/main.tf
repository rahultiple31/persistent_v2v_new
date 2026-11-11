################################################################################
# IAM Module
# Creates:
#   • ECS Task Execution Role  (pull from ECR, write CloudWatch logs)
#   • ECS Task Role            (call Bedrock / Transcribe / Translate / Polly /
#                               SSM, read the sign-in secrets in Secrets
#                               Manager (bff, test sign-in password), and the
#                               voicemail recordings in S3 — never exposed to
#                               the browser)
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

# ── Policy 4 (optional): Secrets Manager — sign-in secrets ────────────────────
# Only created when secret_names is not empty (auth_mode = "bff", or the test
# sign-in). The secrets (the identity provider's client secret, the session
# key, the test sign-in password) are created by hand; Terraform only grants
# read access, by name: Secrets Manager adds 6 random characters to each
# secret's ARN.

data "aws_iam_policy_document" "sign_in_secrets" {
  count = length(var.secret_names) > 0 ? 1 : 0

  statement {
    sid     = "ReadSignInSecrets"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]

    resources = [
      for name in var.secret_names :
      "arn:${var.partition}:secretsmanager:${var.aws_region}:${var.account_id}:secret:${name}-??????"
    ]
  }

  # Only needed if a secret is encrypted with a customer managed key; only
  # through Secrets Manager.
  statement {
    sid       = "DecryptSignInSecrets"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["arn:${var.partition}:kms:${var.aws_region}:${var.account_id}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "sign_in_secrets" {
  count = length(var.secret_names) > 0 ? 1 : 0

  name   = "secretsmanager-sign-in"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.sign_in_secrets[0].json
}

# ── Policy 5 (optional): S3 — voicemail recordings ────────────────────────────
# Only created when voicemail_recordings_bucket is set. The proxy plays VMX3
# voicemail recordings in the page (GET /api/voicemail): read-only, and only
# the recordings (VMX3 names them <date>/<contact ID>.wav).
# Mirrors CDK: PrivatePocStack > if (voicemailBucket).

data "aws_iam_policy_document" "voicemail" {
  count = var.voicemail_recordings_bucket != "" ? 1 : 0

  statement {
    sid       = "ReadVoicemailRecordings"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:${var.partition}:s3:::${var.voicemail_recordings_bucket}/*.wav"]
  }

  # The bucket's KMS key, if it has one (its key policy must let IAM grant
  # access); only through S3, where s3:GetObject above limits it to this bucket.
  statement {
    sid       = "DecryptVoicemailRecordings"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["arn:${var.partition}:kms:${var.aws_region}:${var.account_id}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "voicemail" {
  count = var.voicemail_recordings_bucket != "" ? 1 : 0

  name   = "s3-voicemail-recordings"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.voicemail[0].json
}
