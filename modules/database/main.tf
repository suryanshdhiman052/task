variable "name" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "rds_sg_id" { type = string }
variable "db_name" { type = string }
variable "username" { type = string }

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-pg"
  subnet_ids = var.private_subnet_ids
  tags       = { Name = "${var.name}-pg" }
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.name}-pg16"
  family = "postgres16"

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

# Single-AZ + t4g.micro is the $150 cap trade-off. Multi-AZ on even db.t3.small
# plus NAT + ALB would land near or over the cap; Multi-AZ on a production-sized
# class would blow it by itself.
resource "aws_db_instance" "this" {
  identifier     = "${var.name}-pg"
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t4g.micro"

  db_name  = var.db_name
  username = var.username

  manage_master_user_password = true

  allocated_storage     = 20
  max_allocated_storage = 50
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.rds_sg_id]
  publicly_accessible    = false
  multi_az               = false
  ca_cert_identifier     = "rds-ca-rsa2048-g1"
  parameter_group_name   = aws_db_parameter_group.this.name
  port                   = 5432

  backup_retention_period    = 7
  backup_window              = "07:00-08:00"
  maintenance_window         = "sun:08:00-sun:09:00"
  delete_automated_backups   = false
  deletion_protection        = false
  skip_final_snapshot        = false
  final_snapshot_identifier  = "${var.name}-pg-final"
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true

  performance_insights_enabled = false
  monitoring_interval          = 0
  apply_immediately            = false

  tags = { Name = "${var.name}-pg" }
}
