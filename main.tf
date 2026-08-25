module "networking" {
  source = "./modules/networking"

  name     = "${var.project}-${var.environment}"
  vpc_cidr = var.vpc_cidr
  app_port = var.container_port
}

module "database" {
  source = "./modules/database"

  name               = "${var.project}-${var.environment}"
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_db_subnet_ids
  rds_sg_id          = module.networking.rds_sg_id
  db_name            = var.db_name
  username           = var.db_username
}

module "compute" {
  source = "./modules/compute"

  name              = "${var.project}-${var.environment}"
  vpc_id            = module.networking.vpc_id
  public_subnet_ids = module.networking.public_subnet_ids
  app_subnet_ids    = module.networking.private_app_subnet_ids
  alb_sg_id         = module.networking.alb_sg_id
  ecs_sg_id         = module.networking.ecs_sg_id
  domain_name       = var.domain_name
  hosted_zone_id    = var.hosted_zone_id
  container_image   = var.container_image
  container_command = var.container_command
  container_port    = var.container_port
  container_user    = var.container_user
  health_path       = var.health_path
  db_secret_arn     = module.database.master_user_secret_arn
  db_host           = module.database.address
  db_port           = module.database.port
  db_name           = var.db_name
}
