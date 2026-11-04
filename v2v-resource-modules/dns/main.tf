################################################################################
# DNS Module
# Creates:
#   • Route 53 A alias record      → ALB internal DNS name
#   • Amazon Connect approved origin → https://<hostname>
#
# Mirrors CDK: PrivatePocStack > Route53 ARecord + ApprovedOrigin
################################################################################

# ── Route 53 A alias record ───────────────────────────────────────────────────

resource "aws_route53_record" "site" {
  zone_id = var.hosted_zone_id
  name    = var.hostname
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# ── Amazon Connect approved origin ───────────────────────────────────────────
# aws_connect_approved_origin does NOT exist in the hashicorp/aws provider.
# The AWS CLI is the correct substitute — this is exactly what CDK's
# AwsCustomResource does under the hood for the ApprovedOrigin construct.
# The null_resource is idempotent: re-applying is a no-op when the origin
# already exists (the CLI exits 0 for duplicates).

locals {
  # Extract the bare instance ID from the full Connect ARN
  # arn:aws:connect:REGION:ACCOUNT:instance/INSTANCE-ID
  connect_instance_id = regex("instance/([^/]+)$", var.connect_instance_arn)[0]
}

resource "null_resource" "connect_approved_origin" {
  # Re-run whenever the instance or origin changes
  triggers = {
    instance_id = local.connect_instance_id
    origin      = var.site_https_origin
  }

  # Register the origin on create / update
  provisioner "local-exec" {
    command = <<-EOT
      aws connect associate-approved-origin \
        --instance-id "${local.connect_instance_id}" \
        --origin      "${var.site_https_origin}"
    EOT
    # ResourceNotFoundException is returned if already associated in some
    # CLI versions; suppress so re-apply does not fail.
    on_failure = continue
  }

  # Deregister the origin on destroy
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      aws connect disassociate-approved-origin \
        --instance-id "${self.triggers.instance_id}" \
        --origin      "${self.triggers.origin}"
    EOT
    on_failure = continue
  }
}
