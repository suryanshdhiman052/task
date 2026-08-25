output "vpc_id" {
  value = module.networking.vpc_id
}

output "alb_dns_name" {
  value = module.compute.alb_dns_name
}

output "api_url" {
  value = "https://${var.domain_name}"
}

output "rds_address" {
  value     = module.database.address
  sensitive = true
}

output "rds_secret_arn" {
  description = "Secrets Manager ARN for the RDS master user. Password never enters Terraform variables."
  value       = module.database.master_user_secret_arn
}

output "assets_bucket" {
  value = module.compute.assets_bucket
}

output "ecr_repository_url" {
  value = module.compute.ecr_repository_url
}

output "ecs_cluster" {
  value = module.compute.cluster_name
}
