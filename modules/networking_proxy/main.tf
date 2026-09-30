data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_availability_zone" "available" {
  for_each = toset(data.aws_availability_zones.available.names)
  name     = each.key
}

locals {
  eligible_availability_zones = [
    for zone_name in sort(data.aws_availability_zones.available.names) : zone_name
    if data.aws_availability_zone.available[zone_name].zone_id != "use1-az3"
  ]
  selected_availability_zones = var.availability_zones == null ? slice(local.eligible_availability_zones, 0, min(2, length(local.eligible_availability_zones))) : var.availability_zones
}

resource "aws_vpc" "proxy" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }

  lifecycle {
    precondition {
      condition     = length(local.selected_availability_zones) == 2 && !contains([for zone_name in local.selected_availability_zones : data.aws_availability_zone.available[zone_name].zone_id], "use1-az3")
      error_message = "The proxy requires two available Availability Zones and CloudFront VPC origins do not support AZ ID use1-az3."
    }
  }
}

resource "aws_internet_gateway" "proxy" {
  vpc_id = aws_vpc.proxy.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.proxy.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.selected_availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-public-${count.index + 1}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id                  = aws_vpc.proxy.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = local.selected_availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-private-${count.index + 1}"
    Tier = "private"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat-eip"
  }
}

resource "aws_nat_gateway" "proxy" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.name_prefix}-nat"
  }

  depends_on = [aws_internet_gateway.proxy]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.proxy.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.proxy.id
  }

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

resource "aws_route_table" "private" {
  count = 2

  vpc_id = aws_vpc.proxy.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.proxy.id
  }

  tags = {
    Name = "${var.name_prefix}-private-rt-${count.index + 1}"
  }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.proxy.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = {
    Name = "${var.name_prefix}-s3-gateway"
  }
}
