variable "name" {
  type        = string
  description = "Stack name prefix for VPC, subnets, and security groups."
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block. Subnets are carved as /24s from this block."

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "app_port" {
  type        = number
  description = "ECS container port used in security group peer rules between ALB and tasks."

  validation {
    condition     = var.app_port >= 1024 && var.app_port <= 65535
    error_message = "app_port must be between 1024 and 65535."
  }
}
