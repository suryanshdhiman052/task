output "alb_dns_name" {
  value = aws_lb.api.dns_name
}

output "assets_bucket" {
  value = aws_s3_bucket.assets.bucket
}

output "ecr_repository_url" {
  value = aws_ecr_repository.api.repository_url
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.api.name
}
