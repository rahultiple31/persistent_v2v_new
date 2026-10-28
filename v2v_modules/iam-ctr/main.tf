resource "aws_iam_policy" "ctr" {
  name   = var.policy_name
  policy = file("${path.module}/policy.json")
}

resource "aws_iam_role_policy_attachment" "ctr" {
  for_each = var.role_names

  role       = each.value
  policy_arn = aws_iam_policy.ctr.arn
}
