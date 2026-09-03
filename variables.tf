variable "aws_region" {
  type        = string
  description = "AWS region for all resources. Must match bootstrap and backend.hcl."
  default     = "us-east-1"
}

variable "project" {
  type        = string
  description = "Project name used as a resource name prefix."
  default     = "catalog"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,14}$", var.project))
    error_message = "project must be lowercase alphanumeric with hyphens, max 15 characters."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment tag (e.g. prod, staging)."
  default     = "prod"

  validation {
    condition     = contains(["prod", "staging", "dev"], var.environment)
    error_message = "environment must be one of: prod, staging, dev."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block. /16 recommended; subnets are carved automatically."
  default     = "10.48.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "domain_name" {
  type        = string
  description = "FQDN served by the ALB (ACM certificate + Route53 alias). Example: api.example.com."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$", var.domain_name))
    error_message = "domain_name must be a valid DNS hostname (e.g. api.example.com)."
  }
}

variable "hosted_zone_id" {
  type        = string
  description = "Route53 public hosted zone ID for ACM DNS validation and the API alias record."

  validation {
    condition     = can(regex("^Z[A-Z0-9]+$", var.hosted_zone_id))
    error_message = "hosted_zone_id must be a Route53 hosted zone ID starting with Z."
  }
}

variable "container_image" {
  type        = string
  description = "Container image URI. First apply uses public Node so the target group is healthy before an ECR push."
  default     = "public.ecr.aws/docker/library/node:20.18-alpine"
}

variable "container_command" {
  type        = list(string)
  description = "Override container command. Inline 8080 listener for first apply; set [] after pushing app/."
  default     = ["node", "-e", "require('http').createServer((q,s)=>{s.writeHead(200);s.end('ok')}).listen(8080,'0.0.0.0')"]
}

variable "container_port" {
  type        = number
  description = "Container and ALB target group port."
  default     = 8080

  validation {
    condition     = var.container_port >= 1024 && var.container_port <= 65535
    error_message = "container_port must be between 1024 and 65535."
  }
}

variable "container_user" {
  type        = string
  description = "ECS container user UID. Must be 1000 (non-root). Enforced here once; compute hardcodes the validated value."
  default     = "1000"

  validation {
    condition     = var.container_user == "1000"
    error_message = "ECS tasks must run as UID 1000 (not root, not an image USER name)."
  }
}

variable "alert_email" {
  type        = string
  description = "Ops mailbox for SNS alarms. Subscription requires manual email confirmation in AWS."

  validation {
    condition     = can(regex("^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "health_path" {
  type        = string
  description = "ALB target group health check path."
  default     = "/"
}

variable "db_name" {
  type        = string
  description = "PostgreSQL database name."
  default     = "catalog"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.db_name))
    error_message = "db_name must start with a letter and contain only letters, digits, and underscores."
  }
}

variable "db_username" {
  type        = string
  description = "RDS master username. Password is managed by Secrets Manager, never stored in Terraform."
  default     = "catalog"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.db_username))
    error_message = "db_username must start with a letter and contain only letters, digits, and underscores."
  }
}
