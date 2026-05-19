output "peering_connection_id" {
  description = "VPC peering connection ID — set this as peer_connection_id in dc4/terraform.tfvars."
  value       = var.peer_vpc_id != "" ? aws_vpc_peering_connection.to_dc4[0].id : ""
}

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
  description = "Stable public IP for Consul DNS — use this in dnsmasq-dual-dc.conf for DC3_CONSUL_EIP."
  value       = var.enable_elastic_ip ? aws_eip.consul_server[0].public_ip : aws_instance.consul_server.public_ip
}

output "consul_dns_nlb_ip" {
  description = "DNS NLB EIP — set as nameserver in resolv.conf or org DNS conditional forwarder for consul.prabhjit-singh.sbx.hashidemos.io."
  value       = aws_eip.consul_dns_nlb.public_ip
}

output "hashicups_private_ips" {
  description = "Map of instance key to private IP (e.g. product-api-1 → 10.10.x.x)."
  value       = { for k, inst in aws_instance.hashicups : k => inst.private_ip }
}

output "hashicups_public_ips" {
  value = { for k, inst in aws_instance.hashicups : k => inst.public_ip }
}

output "security_group_id" {
  value = aws_security_group.dc3.id
}

output "consul_retry_join_hint" {
  value = "export DC3_IP=${aws_instance.consul_server.private_ip}"
}

output "vpc_cidr" {
  description = "DC3 VPC CIDR — pass as dc3_vpc_cidr in terraform/dc5/terraform.tfvars."
  value       = var.vpc_cidr
}

output "product_api_private_ips" {
  description = "Private IPs for all product-api instances — used in prepared query and ESM registration."
  value = {
    for k, inst in aws_instance.hashicups : k => inst.private_ip
    if startswith(k, "product-api")
  }
}
