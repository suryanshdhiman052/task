data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
  # NAT in public[0]. Interface endpoints in both app subnets so ECR/secrets survive AZ loss.
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

resource "aws_subnet" "tier" {
  for_each = {
    for pair in setproduct(["public", "app", "db"], range(2)) :
    "${pair[0]}-${pair[1]}" => {
      tier   = pair[0]
      idx    = pair[1]
      extra  = { public = 0, app = 10, db = 20 }[pair[0]]
      public = pair[0] == "public"
    }
  }
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, each.value.extra + each.value.idx)
  availability_zone       = local.azs[each.value.idx]
  map_public_ip_on_launch = each.value.public
  tags                    = { Name = "${var.name}-${each.value.tier}-${local.azs[each.value.idx]}" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat" }
}

# $150 cap: one NAT. NAT #2 is ~$36.45 idle and still dies with AZ[0] unless
# app[1] gets its own route table. Endpoints below are the cheaper mitigation.
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.tier["public-0"].id
  tags          = { Name = var.name }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each       = { for i in range(2) : i => i }
  subnet_id      = aws_subnet.tier["public-${each.key}"].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "app" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-app" }
}

resource "aws_route" "app_nat" {
  route_table_id         = aws_route_table.app.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "app" {
  for_each       = { for i in range(2) : i => i }
  subnet_id      = aws_subnet.tier["app-${each.key}"].id
  route_table_id = aws_route_table.app.id
}

resource "aws_route_table" "db" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-db" }
}

resource "aws_route_table_association" "db" {
  for_each       = { for i in range(2) : i => i }
  subnet_id      = aws_subnet.tier["db-${each.key}"].id
  route_table_id = aws_route_table.db.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.app.id, aws_route_table.db.id]
  tags              = { Name = "${var.name}-s3" }
}

resource "aws_security_group" "vpce" {
  name        = "${var.name}-vpce"
  description = "Interface endpoints — 443 from ECS only"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-vpce" }
}

# ecr.api / ecr.dkr / secretsmanager in both app AZs. ~$22/mo per endpoint vs NAT #2 ~$36.
# Layers already use the S3 gateway. awslogs still needs NAT (no logs endpoint).
resource "aws_vpc_endpoint" "iface" {
  for_each = toset(["ecr.api", "ecr.dkr", "secretsmanager"])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for i in range(2) : aws_subnet.tier["app-${i}"].id]
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true
  tags                = { Name = "${var.name}-${each.key}" }
}

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public ALB"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-alb" }
}

resource "aws_security_group" "ecs" {
  name        = "${var.name}-ecs"
  description = "Fargate tasks"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-ecs" }
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds"
  description = "Postgres — private, ECS only"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.name}-rds" }
}

resource "aws_security_group_rule" "alb_in" {
  for_each          = toset(["80", "443"])
  type              = "ingress"
  security_group_id = aws_security_group.alb.id
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "ecs_dns" {
  for_each          = toset(["tcp", "udp"])
  type              = "egress"
  security_group_id = aws_security_group.ecs.id
  from_port         = 53
  to_port           = 53
  protocol          = each.key
  cidr_blocks       = [var.vpc_cidr]
}

resource "aws_security_group_rule" "ecs_https" {
  type              = "egress"
  security_group_id = aws_security_group.ecs.id
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "logs and other AWS APIs still via NAT"
}

resource "aws_security_group_rule" "peer" {
  for_each = {
    alb_to_ecs    = { sg = aws_security_group.alb.id, type = "egress", port = var.app_port, peer = aws_security_group.ecs.id }
    ecs_from_alb  = { sg = aws_security_group.ecs.id, type = "ingress", port = var.app_port, peer = aws_security_group.alb.id }
    ecs_to_rds    = { sg = aws_security_group.ecs.id, type = "egress", port = 5432, peer = aws_security_group.rds.id }
    rds_from_ecs  = { sg = aws_security_group.rds.id, type = "ingress", port = 5432, peer = aws_security_group.ecs.id }
    vpce_from_ecs = { sg = aws_security_group.vpce.id, type = "ingress", port = 443, peer = aws_security_group.ecs.id }
  }
  type                     = each.value.type
  security_group_id        = each.value.sg
  from_port                = each.value.port
  to_port                  = each.value.port
  protocol                 = "tcp"
  source_security_group_id = each.value.peer
}
