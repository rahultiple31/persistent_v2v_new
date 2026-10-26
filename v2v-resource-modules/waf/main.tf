################################################################################
# WAF Module
# Creates:
#   • WAF v2 WebACL   (IP reputation list, known-bad inputs, optional common set)
#   • WebACL association with the ALB
#
# Mirrors CDK: PrivatePocStack > Load balancer > webAcl + WebAclAssociation
################################################################################

resource "aws_wafv2_web_acl" "main" {
  name  = "${var.stack_name}-web-acl"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # Priority 0 — AWS IP reputation list (known malicious IPs)
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 0

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesAmazonIpReputationList"
      sampled_requests_enabled   = true
    }
  }

  # Priority 1 — Known bad inputs (log4j, SQL injection patterns, etc.)
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Priority 2 — Common rule set (optional; body-size rule in COUNT so
  # /api/fallback bodies up to 16 KB are not blocked by the 8 KB limit)
  dynamic "rule" {
    for_each = var.common_rule_set ? [1] : []

    content {
      name     = "AWSManagedRulesCommonRuleSet"
      priority = 2

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = "AWSManagedRulesCommonRuleSet"

          # Override only the body-size restriction to COUNT so large Polly
          # request bodies (up to 16 KB) are not blocked
          rule_action_override {
            name = "SizeRestrictions_BODY"
            action_to_use {
              count {}
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "AWSManagedRulesCommonRuleSet"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.stack_name}-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.stack_name}-web-acl"
  }
}

# ── Associate the WebACL with the ALB ─────────────────────────────────────────

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}
