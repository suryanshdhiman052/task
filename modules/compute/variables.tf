variable "name" {
  type        = string
  description = "Stack name prefix for ECS, ALB, ECR, and IAM resources."
}

variable "vpc_id" {
  type        = string
  description = "VPC where the ALB target group and internal Route53 zone are created."
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnets for the internet-facing ALB."

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "public_subnet_ids must include at least two subnets for ALB high availability."
  }
}

variable "app_subnet_ids" {
  type        = list(string)
  description = "Private app subnets for Fargate tasks (no public IP)."

  validation {
    condition     = length(var.app_subnet_ids) >= 2
    error_message = "app_subnet_ids must include at least two subnets for multi-AZ ECS."
  }
}

variable "alb_sg_id" {
  type        = string
  description = "Security group attached to the ALB."
}

variable "ecs_sg_id" {
  type        = string
  description = "Security group attached to Fargate tasks."
}

variable "domain_name" {
  type        = string
  description = "Public FQDN served by the ALB (ACM certificate + Route53 alias)."
}

variable "hosted_zone_id" {
  type        = string
  description = "Route53 public hosted zone for ACM validation and the API alias record."
}

variable "container_image" {
  type        = string
  description = "Container image URI. First apply uses a public Node image; switch to ECR after push-api.sh."
}

variable "container_command" {
  type        = list(string)
  description = "Override container command. Default inline listener keeps the target group healthy before ECR push."
}

variable "container_port" {
  type        = number
  description = "Container and target group port."

  validation {
    condition     = var.container_port >= 1024 && var.container_port <= 65535
    error_message = "container_port must be between 1024 and 65535."
  }
}

variable "container_user" {
  type        = string
  description = "ECS container user UID. Validated once at root; must be 1000."
}

variable "health_path" {
  type        = string
  description = "ALB target group health check path."
}

variable "assets_bucket" {
  type        = string
  description = "S3 bucket name injected as ASSETS_BUCKET env var (not an IAM grant)."
}

variable "assets_bucket_arn" {
  type        = string
  description = "ARN scoped in the task role for object read/write."
}

variable "db_secret_arn" {
  type        = string
  description = "Secrets Manager ARN for RDS master credentials (execution role GetSecretValue only)."
}

variable "db_host" {
  type        = string
  description = "RDS endpoint written to the private postgres CNAME."
}

variable "db_port" {
  type        = number
  description = "PostgreSQL port injected as DB_PORT."
}

variable "db_name" {
  type        = string
  description = "Database name injected as DB_NAME."
}
