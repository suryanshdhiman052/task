variable "name" {
  type        = string
  description = "Stack name prefix for RDS instance and subnet group."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID (used for tagging; RDS placement is via subnet group)."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private database subnets. RDS is not publicly accessible."

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "private_subnet_ids must include at least two subnets for the RDS subnet group."
  }
}

variable "rds_sg_id" {
  type        = string
  description = "Security group allowing PostgreSQL ingress from ECS tasks only."
}

variable "db_name" {
  type        = string
  description = "Initial PostgreSQL database name."

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.db_name))
    error_message = "db_name must start with a letter and contain only letters, digits, and underscores."
  }
}

variable "username" {
  type        = string
  description = "RDS master username. Password is managed by Secrets Manager."

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]{0,62}$", var.username))
    error_message = "username must start with a letter and contain only letters, digits, and underscores."
  }
}
