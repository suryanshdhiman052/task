output "alb_dns_name" {
  value = aws_lb.api.dns_name
}

output "assets_bucket" {
  value = var.assets_bucket
}

output "ecr_repository_url" {
  value = aws_ecr_repository.api.repository_url
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "service_name" {
  value = aws_ecs_service.api.name
}

output "db_cname" {
  value       = aws_route53_record.postgres.fqdn
  description = "Stable DB_HOST. Flip the CNAME after a snapshot restore; do not rewrite the task env."
}
