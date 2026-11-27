data "aws_iam_role" "execution" {
  name = reverse(split("/", var.role_arn))[0]

  lifecycle {
    postcondition {
      condition     = self.arn == var.role_arn
      error_message = "The resolved IAM role ARN must match the requested role ARN."
    }
  }
}

resource "aws_iam_role_policy_attachment" "managed" {
  role       = data.aws_iam_role.execution.name
  policy_arn = var.policy_arn
}
