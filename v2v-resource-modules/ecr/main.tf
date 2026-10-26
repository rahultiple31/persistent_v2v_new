################################################################################
# ECR Module
# Creates:
#   • ECR private repository  (image scanning on push, AES-256 encryption)
#   • Lifecycle policy        (keeps last 10 tagged images, removes untagged
#                              after 1 day — same behaviour as CDK asset repos)
#
# Mirrors CDK: ContainerImage.fromAsset() → cdk-assets ECR repository
################################################################################

resource "aws_ecr_repository" "proxy" {
  name                 = var.repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = var.repository_name
  }
}

resource "aws_ecr_lifecycle_policy" "proxy" {
  repository = aws_ecr_repository.proxy.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last 10 tagged releases"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "release", "latest"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}
