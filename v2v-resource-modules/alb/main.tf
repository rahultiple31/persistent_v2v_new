################################################################################
# ALB Module
# Creates:
#   • S3 bucket for ALB access logs   (encrypted, SSL-enforced, 90-day lifecycle)
#   • Application Load Balancer       (internal, drop invalid headers, 120 s idle)
#   • HTTP or HTTPS listener          (TLS 1.2+ when certificate_arn is set)
#   • Target group                    (IP targets, port 8080, /healthz health check)
#
# Mirrors CDK: PrivatePocStack > Load balancer section
################################################################################

data "aws_elb_service_account" "main" {}

# ── S3 bucket for ALB access logs ─────────────────────────────────────────────

resource "aws_s3_bucket" "alb_logs" {
  bucket = lower("${var.stack_name}-alb-logs-${var.account_id}")

  # CDK RemovalPolicy.RETAIN: do NOT force-destroy so log data is preserved on
  # terraform destroy. Empty the bucket manually at teardown.
  force_destroy = false

  tags = {
    Name = "${var.stack_name}-alb-logs"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-logs-after-90-days"
    status = "Enabled"

    # An empty filter block applies the rule to every object in the bucket.
    # One of filter or prefix is required by the AWS provider >= 4.x;
    # omitting it produces the "Invalid Attribute Combination" warning.
    filter {}

    expiration {
      days = 90
    }
  }
}

# Enforce HTTPS-only access to the log bucket
resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = data.aws_iam_policy_document.alb_logs_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}

data "aws_iam_policy_document" "alb_logs_bucket" {
  # Allow the regional ELB service account to write access logs
  statement {
    sid    = "AllowELBServiceAccount"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.main.arn]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${var.account_id}/*"]
  }

  # Allow the delivery.logs service to put objects (newer regions use this instead)
  statement {
    sid    = "AllowLogDeliveryPutObject"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${var.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  # Allow the delivery.logs service to read the bucket ACL
  statement {
    sid    = "AllowLogDeliveryGetAcl"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.alb_logs.arn]
  }

  # Deny any non-HTTPS requests (enforceSSL)
  statement {
    sid    = "DenyNonHttps"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.alb_logs.arn, "${aws_s3_bucket.alb_logs.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# ── Application Load Balancer ─────────────────────────────────────────────────

resource "aws_lb" "main" {
  name                       = "${var.stack_name}-alb"
  internal                   = true
  load_balancer_type         = "application"
  security_groups            = [var.alb_security_group_id]
  subnets                    = var.subnet_ids
  idle_timeout               = 120
  drop_invalid_header_fields = true
  enable_deletion_protection = false

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "alb"
    enabled = true
  }

  tags = {
    Name = "${var.stack_name}-alb"
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]
}

# ── Target Group ──────────────────────────────────────────────────────────────
# Standalone target group so the ALB listener can be moved from HTTP to HTTPS
# without recreating the service registration (matches CDK design intent).

resource "aws_lb_target_group" "proxy" {
  name        = "${var.stack_name}-proxy-tg"
  port        = 8080
  protocol    = "HTTPS"
  target_type = "ip"
  vpc_id      = var.vpc_id

  # Longer than a Nova Sonic session (8 min). In-flight sessions reach their
  # natural 7.5 min proactive restart before the task is stopped. (CDK: 480 s)
  deregistration_delay = 480

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.stack_name}-proxy-tg"
  }
}

# ── Listener — HTTP (no certificate) ─────────────────────────────────────────

resource "aws_lb_listener" "http" {
  count             = var.https ? 0 : 1
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTPS"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.proxy.arn
  }

  tags = {
    Name = "${var.stack_name}-listener-https"
  }
}

# ── Listener — HTTPS (TLS 1.2 + 1.3, recommended policy) ─────────────────────

resource "aws_lb_listener" "https" {
  count             = var.https ? 1 : 0
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.certificate_arn
  # ELBSecurityPolicy-TLS13-1-2-2021-06 is the CDK RECOMMENDED_TLS policy
  ssl_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.proxy.arn
  }

  tags = {
    Name = "${var.stack_name}-listener-https"
  }
}
