# Retire the old deployment resources without deleting a deployed Lambda.
# Follow ../../docs/native-lambda-migration.md before the first native deployment.
# These blocks only forget legacy state; they create no CloudFormation or S3 resources.
removed {
  from = aws_cloudformation_stack.lambda
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_object.code
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_public_access_block.code
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket.code
  lifecycle {
    destroy = false
  }
}
