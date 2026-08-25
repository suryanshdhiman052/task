output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  value = aws_subnet.app[*].id
}

output "private_db_subnet_ids" {
  value = aws_subnet.db[*].id
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
  description = "AZ that hosts the single NAT Gateway — private egress dies if this AZ is down"
  value       = aws_subnet.public[0].availability_zone
}
