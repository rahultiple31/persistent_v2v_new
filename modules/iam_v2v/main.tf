data "aws_iam_policy_document" "unauthenticated_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["cognito-identity.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "cognito-identity.amazonaws.com:aud"
      values   = [var.identity_pool_id]
    }

    condition {
      test     = "ForAnyValue:StringLike"
      variable = "cognito-identity.amazonaws.com:amr"
      values   = ["unauthenticated"]
    }
  }
}

data "aws_iam_policy_document" "authenticated_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["cognito-identity.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "cognito-identity.amazonaws.com:aud"
      values   = [var.identity_pool_id]
    }

    condition {
      test     = "ForAnyValue:StringLike"
      variable = "cognito-identity.amazonaws.com:amr"
      values   = ["authenticated"]
    }
  }
}

resource "aws_iam_role" "unauthenticated" {
  name               = "${var.name_prefix}-unauthenticated"
  assume_role_policy = data.aws_iam_policy_document.unauthenticated_assume_role.json
  tags               = var.common_tags
}

resource "aws_iam_role" "authenticated" {
  name               = "${var.name_prefix}-authenticated"
  assume_role_policy = data.aws_iam_policy_document.authenticated_assume_role.json
  tags               = var.common_tags
}

data "aws_iam_policy_document" "unauthenticated_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "mobileanalytics:PutEvents",
      "cognito-sync:*"
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "authenticated_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "mobileanalytics:PutEvents",
      "cognito-sync:*",
      "cognito-identity:*",
      "polly:SynthesizeSpeech",
      "polly:DescribeVoices",
      "transcribe:StartStreamTranscription",
      "transcribe:StartStreamTranscriptionWebSocket",
      "translate:ListLanguages",
      "translate:TranslateText",
      "cognito-identity:GetCredentialsForIdentity"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "unauthenticated" {
  name   = "${var.name_prefix}-unauthenticated"
  role   = aws_iam_role.unauthenticated.id
  policy = data.aws_iam_policy_document.unauthenticated_permissions.json
}

resource "aws_iam_role_policy" "authenticated" {
  name   = "${var.name_prefix}-authenticated"
  role   = aws_iam_role.authenticated.id
  policy = data.aws_iam_policy_document.authenticated_permissions.json
}

resource "aws_cognito_identity_pool_roles_attachment" "this" {
  identity_pool_id = var.identity_pool_id

  roles = {
    authenticated   = aws_iam_role.authenticated.arn
    unauthenticated = aws_iam_role.unauthenticated.arn
  }
}
