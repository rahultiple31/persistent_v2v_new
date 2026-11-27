locals {
  security_group_name = "BTSGSD-V2V-US-LAMBDA-internet-sg"
}

resource "aws_security_group" "lambda_internet" {
  name        = local.security_group_name
  description = "Lambda HTTPS access to ServiceNow through the central firewall"
  vpc_id      = var.vpc_id

  tags = {
    Name = local.security_group_name
  }
}

# The central firewall restricts HTTPS traffic to the ServiceNow hosts.
resource "aws_vpc_security_group_egress_rule" "https_ipv4" {
  security_group_id = aws_security_group.lambda_internet.id
  description       = "HTTPS through the central firewall"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}
