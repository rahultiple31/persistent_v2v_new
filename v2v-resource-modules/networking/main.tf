################################################################################
# Networking Module
# Creates:
#   • ALB security group        (ingress from VDI CIDRs, egress to service SG)
#   • Service security group    (ingress from ALB SG, egress 443 to anywhere)
#   • Endpoint security group   (ingress 443 from service SG + extra CIDRs)
#   • VPC interface endpoints   (Bedrock, Transcribe, Translate, Polly, SSM,
#                                ECR API, ECR Docker, CloudWatch Logs)
#
# Mirrors CDK: PrivatePocStack > Network section
################################################################################

# ── ALB Security Group ────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${var.stack_name}-alb-sg"
  description = "V2V POC load balancer: port ${var.listener_port} from the VDI only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.stack_name}-alb-sg"
  }
}

# Ingress from each allowed CIDR (VDI / Zscaler connectors)
resource "aws_vpc_security_group_ingress_rule" "alb_from_cidrs" {
  for_each          = toset(var.allowed_cidrs)
  security_group_id = aws_security_group.alb.id
  description       = "VDI / approved client"
  cidr_ipv4         = each.value
  from_port         = var.listener_port
  to_port           = var.listener_port
  ip_protocol       = "tcp"
}

# Egress from ALB to proxy tasks on container port 8080
resource "aws_vpc_security_group_egress_rule" "alb_to_service" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to proxy Fargate tasks"
  referenced_security_group_id = aws_security_group.service.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

# ── Service (Fargate tasks) Security Group ────────────────────────────────────

resource "aws_security_group" "service" {
  name        = "${var.stack_name}-service-sg"
  description = "V2V POC proxy tasks: traffic from the load balancer only; HTTPS out"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.stack_name}-service-sg"
  }
}

# Ingress from the ALB on container port
resource "aws_vpc_security_group_ingress_rule" "service_from_alb" {
  security_group_id            = aws_security_group.service.id
  description                  = "From the load balancer"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
}

# Egress: HTTPS to VPC endpoints, S3 gateway endpoint, identity provider JWKS
resource "aws_vpc_security_group_egress_rule" "service_egress_https" {
  security_group_id = aws_security_group.service.id
  description       = "VPC endpoints, S3 gateway endpoint, identity provider keys"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# ── Endpoint Security Group ───────────────────────────────────────────────────

resource "aws_security_group" "endpoint" {
  name        = "${var.stack_name}-endpoint-sg"
  description = "V2V POC VPC endpoints: HTTPS from the proxy tasks"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.stack_name}-endpoint-sg"
  }
}

# Ingress from proxy tasks
resource "aws_vpc_security_group_ingress_rule" "endpoint_from_service" {
  security_group_id            = aws_security_group.endpoint.id
  description                  = "Proxy tasks"
  referenced_security_group_id = aws_security_group.service.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

# Ingress from any extra VPC CIDRs that also call these services
resource "aws_vpc_security_group_ingress_rule" "endpoint_from_extra_cidrs" {
  for_each          = toset(var.endpoint_extra_cidrs)
  security_group_id = aws_security_group.endpoint.id
  description       = "Other callers in the VPC"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# ── VPC Interface Endpoints ───────────────────────────────────────────────────
# Private DNS is enabled: the AWS SDK's standard service hostnames resolve to
# these private addresses, so no code changes are needed in the proxy.
# The endpoint security group must exist before the endpoints so that private
# DNS takes effect with the ingress rules already in place.

locals {
  # Map of logical name -> VPC endpoint service name
  interface_endpoints = {
    bedrock_runtime      = "com.amazonaws.${var.aws_region}.bedrock-runtime"
    transcribe_streaming = "com.amazonaws.${var.aws_region}.transcribestreaming"
    translate            = "com.amazonaws.${var.aws_region}.translate"
    polly                = "com.amazonaws.${var.aws_region}.polly"
    ssm                  = "com.amazonaws.${var.aws_region}.ssm"
    ecr_api              = "com.amazonaws.${var.aws_region}.ecr.api"
    ecr_dkr              = "com.amazonaws.${var.aws_region}.ecr.dkr"
    logs                 = "com.amazonaws.${var.aws_region}.logs"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = var.vpc_id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.endpoint.id]

  tags = {
    Name = "${var.stack_name}-endpoint-${replace(each.key, "_", "-")}"
  }

  # Endpoint security group ingress rules must be in place before endpoints
  # so private DNS resolves correctly from the moment the endpoint exists.
  depends_on = [
    aws_vpc_security_group_ingress_rule.endpoint_from_service,
    aws_vpc_security_group_ingress_rule.endpoint_from_extra_cidrs,
  ]
}
