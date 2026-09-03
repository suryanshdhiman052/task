output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = [for i in range(2) : aws_subnet.tier["public-${i}"].id]
}

output "private_app_subnet_ids" {
  value = [for i in range(2) : aws_subnet.tier["app-${i}"].id]
}

output "private_db_subnet_ids" {
  value = [for i in range(2) : aws_subnet.tier["db-${i}"].id]
}

output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "ecs_sg_id" {
  value = aws_security_group.ecs.id
}

output "rds_sg_id" {
  value = aws_security_group.rds.id
}

output "nat_az" {
  description = "AZ of the single NAT. Private egress dies if this AZ is down; ECR/secrets still work via interface endpoints in both app subnets."
  value       = aws_subnet.tier["public-0"].availability_zone
}
