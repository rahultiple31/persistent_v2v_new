output "secret_arns" {
  description = "Secret names and ARNs; excludes secret values."

  value = {
    for name, secret in aws_secretsmanager_secret.this :
    name => secret.arn
  }
}
