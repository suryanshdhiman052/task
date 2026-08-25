variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "catalog"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "vpc_cidr" {
  type    = string
  default = "10.48.0.0/16"
}

variable "domain_name" {
  type        = string
  description = "FQDN served by the ALB (ACM + Route53). Example: api.example.com"
}

variable "hosted_zone_id" {
  type        = string
  description = "Route53 public hosted zone that can create the ACM validation and alias records"
}

variable "container_image" {
  type        = string
  description = "API image. Default is public Node, non-root, so the first apply has a live target without an ECR push."
  default     = "public.ecr.aws/docker/library/node:20.18-alpine"
}

variable "container_command" {
  type        = list(string)
  description = "Override CMD. Default is a non-root health listener on 8080. Replace with [] after pushing app/ to ECR."
  default = [
    "node",
    "-e",
    "require('http').createServer((q,s)=>{s.writeHead(200,{'content-type':'application/json'});s.end(JSON.stringify({ok:true,path:q.url}))}).listen(8080,'0.0.0.0')",
  ]
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "container_user" {
  type        = string
  description = "Numeric or named user inside the image. Must not be root."
  default     = "node"

  validation {
    condition     = !contains(["", "root", "0", "0:0"], var.container_user)
    error_message = "ECS tasks in this stack must not run as root."
  }
}

variable "health_path" {
  type    = string
  default = "/"
}

variable "db_name" {
  type    = string
  default = "catalog"
}

variable "db_username" {
  type    = string
  default = "catalog"
}
