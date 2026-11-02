# Rules are managed separately to avoid circular group dependencies.
resource "aws_security_group" "endpoint" {
  name        = "BTSGSD-V2V-US-LAMBDA-endpoint-sg"
  description = "Interface endpoints for the Connect Lambdas"
  vpc_id      = var.vpc_id

  tags = merge(var.common_tags, {
    Name = "BTSGSD-V2V-US-LAMBDA-endpoint-sg"
  })
}

resource "aws_security_group" "core" {
  name        = "BTSGSD-V2V-US-LAMBDA-core-sg"
  description = "Connect Lambdas - AWS services only"
  vpc_id      = var.vpc_id

  tags = merge(var.common_tags, {
    Name = "BTSGSD-V2V-US-LAMBDA-core-sg"
  })
}

# Endpoint inbound: HTTPS from the new V2V Lambda core group.
resource "aws_vpc_security_group_ingress_rule" "endpoint_from_core" {
  security_group_id            = aws_security_group.endpoint.id
  referenced_security_group_id = aws_security_group.core.id
  description                  = "HTTPS from Connect Lambdas"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443

  tags = var.common_tags
}

# Core outbound rule 1: HTTPS to interface endpoints.
resource "aws_vpc_security_group_egress_rule" "core_to_endpoints" {
  security_group_id            = aws_security_group.core.id
  referenced_security_group_id = aws_security_group.endpoint.id
  description                  = "HTTPS to AWS interface endpoints"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443

  tags = var.common_tags
}

# Core outbound rule 2: HTTPS to the S3 managed prefix list.
resource "aws_vpc_security_group_egress_rule" "core_to_s3" {
  security_group_id = aws_security_group.core.id
  prefix_list_id    = "pl-63a5400a"
  description       = "HTTPS to Amazon S3"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  tags = var.common_tags
}

# Core outbound rule 3: HTTPS to the DynamoDB managed prefix list.
resource "aws_vpc_security_group_egress_rule" "core_to_dynamodb" {
  security_group_id = aws_security_group.core.id
  prefix_list_id    = "pl-02cd2c6b"
  description       = "HTTPS to Amazon DynamoDB"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  tags = var.common_tags
}

# No core ingress rules or endpoint egress rules.
# No inline rules or allow-all egress rules.
