# Private zone so DB_HOST survives a snapshot restore without rewriting task env.
resource "aws_route53_zone" "internal" {
  name = "${var.name}.internal"

  vpc {
    vpc_id = var.vpc_id
  }
}

resource "aws_route53_record" "postgres" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "postgres"
  type    = "CNAME"
  ttl     = 30
  records = [var.db_host]
}

resource "aws_route53_record" "api" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.api.dns_name
    zone_id                = aws_lb.api.zone_id
    evaluate_target_health = true
  }
}
