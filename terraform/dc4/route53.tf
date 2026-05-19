locals {
  r53_enabled = var.route53_public_zone_name != "" && var.enable_public_ip
}

data "aws_route53_zone" "public" {
  count        = local.r53_enabled ? 1 : 0
  name         = var.route53_public_zone_name
  private_zone = false
}

resource "aws_route53_record" "dc4_server_public" {
  count   = local.r53_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = "consul.dc4"
  type    = "A"
  ttl     = 300
  records = [var.enable_elastic_ip ? aws_eip.consul_server[0].public_ip : aws_instance.consul_server.public_ip]
}

resource "aws_route53_record" "dc4_terminating_gw_public" {
  count   = local.r53_enabled ? 1 : 0
  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = "terminating-gw.dc4"
  type    = "A"
  ttl     = 300
  records = [aws_instance.terminating_gw.public_ip]
}

# One record per unique service name, prefixed with dc4. to avoid collisions.
resource "aws_route53_record" "hashicups_public" {
  for_each = local.r53_enabled ? {
    for k, inst in aws_instance.hashicups : local.hashicups_instances[k] => inst.public_ip...
  } : {}
  zone_id = data.aws_route53_zone.public[0].zone_id
  name    = "${each.key}.dc4"
  type    = "A"
  ttl     = 300
  records = [each.value[0]]
}
