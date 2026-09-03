data "aws_region" "current" {}

locals {
  log_group = "/ecs/${var.name}"

  container = merge(
    {
      name      = "api"
      image     = var.container_image
      user      = var.container_user
      essential = true
      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]
      environment = [
        { name = "PORT", value = tostring(var.container_port) },
        { name = "DB_HOST", value = aws_route53_record.postgres.fqdn },
        { name = "DB_PORT", value = tostring(var.db_port) },
        { name = "DB_NAME", value = var.db_name },
        { name = "ASSETS_BUCKET", value = var.assets_bucket },
      ]
      secrets = [
        { name = "DB_USERNAME", valueFrom = "${var.db_secret_arn}:username::" },
        { name = "DB_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" },
      ]
      readonlyRootFilesystem = true
      privileged             = false
      linuxParameters = {
        capabilities       = { drop = ["ALL"] }
        initProcessEnabled = true
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = local.log_group
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "api"
        }
      }
    },
    length(var.container_command) == 0 ? {} : { command = var.container_command }
  )
}
