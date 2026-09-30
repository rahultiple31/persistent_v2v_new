data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Allow HTTP from CloudFront origin-facing addresses only"
  vpc_id      = var.vpc_id

  revoke_rules_on_delete = true

  tags = {
    Name = "${var.name_prefix}-alb-sg"
  }
}

resource "aws_security_group" "service" {
  name        = "${var.name_prefix}-service-sg"
  description = "Allow proxy container traffic only from the internal ALB and HTTPS egress"
  vpc_id      = var.vpc_id

  revoke_rules_on_delete = true

  tags = {
    Name = "${var.name_prefix}-service-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "CloudFront VPC origin to internal ALB"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id
}

resource "aws_vpc_security_group_egress_rule" "alb_service" {
  security_group_id            = aws_security_group.alb.id
  description                  = "ALB to proxy containers"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.service.id
}

resource "aws_vpc_security_group_ingress_rule" "service_alb" {
  security_group_id            = aws_security_group.service.id
  description                  = "ALB to proxy containers"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "service_https" {
  security_group_id = aws_security_group.service.id
  description       = "HTTPS to AWS APIs through NAT"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}
