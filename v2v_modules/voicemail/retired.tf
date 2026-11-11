# Recordings bucket rename: btsgsd-v2v-us-voicemail -> btsgsd-v2v-us-voicemail-recording.
#
# S3 buckets cannot be renamed, and Terraform only empties a versioned bucket
# on delete when force_destroy = true is already saved in state. So:
#
#   Run A (delete_retired_recordings_bucket = false):
#     the old bucket moves to aws_s3_bucket.retired_recordings[0] and gets
#     force_destroy = true (in-place); its eight setting resources are
#     forgotten, not deleted (they disappear with the bucket in Run B).
#   Run B (delete_retired_recordings_bucket = true):
#     Terraform empties and deletes the old bucket.
#
# After Run B these blocks can stay; they are no-ops once the state is clean.

locals {
  retired_recordings_bucket_name = lower("${var.name_prefix}-voicemail")
}

resource "aws_s3_bucket" "retired_recordings" {
  count = var.delete_retired_recordings_bucket ? 0 : 1

  bucket              = local.retired_recordings_bucket_name
  object_lock_enabled = true
  force_destroy       = true
  tags                = merge(var.tags, { Name = local.retired_recordings_bucket_name })
}

moved {
  from = aws_s3_bucket.this["recordings"]
  to   = aws_s3_bucket.retired_recordings[0]
}

# Bucket settings: forgotten (destroy = false); deleted together with the bucket.
moved {
  from = aws_s3_bucket_ownership_controls.this["recordings"]
  to   = aws_s3_bucket_ownership_controls.retired_recordings
}

removed {
  from = aws_s3_bucket_ownership_controls.retired_recordings
  lifecycle {
    destroy = false
  }
}

moved {
  from = aws_s3_bucket_public_access_block.this["recordings"]
  to   = aws_s3_bucket_public_access_block.retired_recordings
}

removed {
  from = aws_s3_bucket_public_access_block.retired_recordings
  lifecycle {
    destroy = false
  }
}

moved {
  from = aws_s3_bucket_acl.this["recordings"]
  to   = aws_s3_bucket_acl.retired_recordings
}

removed {
  from = aws_s3_bucket_acl.retired_recordings
  lifecycle {
    destroy = false
  }
}

moved {
  from = aws_s3_bucket_versioning.this["recordings"]
  to   = aws_s3_bucket_versioning.retired_recordings
}

removed {
  from = aws_s3_bucket_versioning.retired_recordings
  lifecycle {
    destroy = false
  }
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.this["recordings"]
  to   = aws_s3_bucket_server_side_encryption_configuration.retired_recordings
}

removed {
  from = aws_s3_bucket_server_side_encryption_configuration.retired_recordings
  lifecycle {
    destroy = false
  }
}

moved {
  from = aws_s3_bucket_notification.this["recordings"]
  to   = aws_s3_bucket_notification.retired_recordings
}

removed {
  from = aws_s3_bucket_notification.retired_recordings
  lifecycle {
    destroy = false
  }
}

moved {
  from = aws_s3_bucket_lifecycle_configuration.this["recordings"]
  to   = aws_s3_bucket_lifecycle_configuration.retired_recordings
}

removed {
  from = aws_s3_bucket_lifecycle_configuration.retired_recordings
  lifecycle {
    destroy = false
  }
}

moved {
  from = aws_s3_bucket_policy.this["recordings"]
  to   = aws_s3_bucket_policy.retired_recordings
}

removed {
  from = aws_s3_bucket_policy.retired_recordings
  lifecycle {
    destroy = false
  }
}
