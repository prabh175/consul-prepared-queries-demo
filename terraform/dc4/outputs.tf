output "vpc_id" {
  value = aws_vpc.this.id
}

output "subnet_ids" {
  value = aws_subnet.public[*].id
}

output "consul_server_private_ip" {
  value = aws_instance.consul_server.private_ip
}

output "consul_server_public_ip" {
  value = var.enable_elastic_ip ? aws_eip.consul_server[0].public_ip : aws_instance.consul_server.public_ip
}

output "consul_dns_endpoint" {
  description = "Stable public IP for Consul DNS — use this in dnsmasq-dual-dc.conf for DC4_CONSUL_EIP."
  value       = var.enable_elastic_ip ? aws_eip.consul_server[0].public_ip : aws_instance.consul_server.public_ip
}

output "consul_dns_nlb_ip" {
  description = "DNS NLB EIP — set as nameserver in resolv.conf or org DNS conditional forwarder for consul.prabhjit-singh.sbx.hashidemos.io."
  value       = aws_eip.consul_dns_nlb.public_ip
}

output "terminating_gw_private_ip" {
  value = aws_instance.terminating_gw.private_ip
}

output "terminating_gw_public_ip" {
  value = aws_instance.terminating_gw.public_ip
}

output "hashicups_private_ips" {
  description = "Map of instance key to private IP. Pass these to register-dc4-services.sh."
  value       = { for k, inst in aws_instance.hashicups : k => inst.private_ip }
}

output "hashicups_public_ips" {
  value = { for k, inst in aws_instance.hashicups : k => inst.public_ip }
}

output "vpc_cidr" {
  description = "DC4 VPC CIDR — pass as dc4_vpc_cidr in terraform/dc6/terraform.tfvars."
  value       = var.vpc_cidr
}

output "product_api_private_ips" {
  description = "Private IPs for DC4 product-api instances — the ESM failover targets."
  value = {
    for k, inst in aws_instance.hashicups : k => inst.private_ip
    if startswith(k, "product-api")
  }
}

output "security_group_id" {
  value = aws_security_group.dc4.id
}

output "consul_retry_join_hint" {
  value = "export DC4_IP=${aws_instance.consul_server.private_ip}"
}
