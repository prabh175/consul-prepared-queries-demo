data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "hc_base_ubuntu" {
  filter {
    name   = "name"
    values = ["hc-base-ubuntu-2404-${var.vm_arch}-*"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
  most_recent = true
  owners      = ["888995627335"]
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
  subnet_cidrs = [
    cidrsubnet(var.vpc_cidr, 4, 0),
    cidrsubnet(var.vpc_cidr, 4, 1),
    cidrsubnet(var.vpc_cidr, 4, 2),
  ]

  hashicups_instances = merge([
    for svc, cnt in var.hashicups_service_counts : {
      for i in range(cnt) :
      (cnt > 1 ? "${svc}-${i + 1}" : svc) => svc
    }
  ]...)

  sorted_instance_keys = sort(keys(local.hashicups_instances))

  # DC4 server: Consul server + mesh-gw + ESM co-located. No monitoring stack.
  user_data_server = <<-EOT
    #!/bin/bash
    set -euo pipefail
    apt-get update -y
    apt-get install -y docker.io unzip
    systemctl enable --now docker
    usermod -aG docker ubuntu || true
  EOT

  # DC4 hashicups VMs: Docker only. No Consul agent. No monitoring.
  # ESM on the server VM health-checks these externally.
  user_data_hashicups = <<-EOT
    #!/bin/bash
    set -euo pipefail
    apt-get update -y
    apt-get install -y docker.io
    systemctl enable --now docker
    usermod -aG docker ubuntu || true
  EOT
}

# ── VPC ──────────────────────────────────────────────────────────────────────

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.project_name}-vpc-dc4" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project_name}-igw-dc4" }
}

resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags = { Name = "${var.project_name}-public-dc4-${count.index + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project_name}-rt-dc4" }
}

resource "aws_route" "igw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Security group ────────────────────────────────────────────────────────────

resource "aws_security_group" "dc4" {
  name        = "${var.project_name}-dc4"
  description = "DC4 consul server + ESM + terminating-gw + external hashicups VMs"
  vpc_id      = aws_vpc.this.id

  # Intra-DC: all VMs share this SG so gossip, ESM health checks and Envoy all route via self.
  ingress {
    description = "All TCP within DC4"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "All UDP within DC4"
    from_port   = 0
    to_port     = 65535
    protocol    = "udp"
    self        = true
  }

  # Mesh gateway — restricted to peer VPC CIDR when VPC peering is active,
  # otherwise open to internet for the initial cross-region connection.
  ingress {
    description = "Mesh gateway (cross-region cluster peering)"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = var.peer_connection_id != "" ? [var.peer_vpc_cidr] : ["0.0.0.0/0"]
  }

  dynamic "ingress" {
    for_each = var.peer_connection_id != "" ? [1] : []
    content {
      description = "Consul gRPC from peer DC (peering control plane)"
      from_port   = 8502
      to_port     = 8503
      protocol    = "tcp"
      cidr_blocks = [var.peer_vpc_cidr]
    }
  }

  dynamic "ingress" {
    for_each = var.operator_public_cidr != "" ? [1] : []
    content {
      description = "Full access from operator laptop"
      from_port   = 0
      to_port     = 65535
      protocol    = "tcp"
      cidr_blocks = [var.operator_public_cidr]
    }
  }

  dynamic "ingress" {
    for_each = var.operator_public_cidr != "" ? [1] : []
    content {
      description = "UDP access from operator laptop (DNS NLB)"
      from_port   = 0
      to_port     = 65535
      protocol    = "udp"
      cidr_blocks = [var.operator_public_cidr]
    }
  }

  dynamic "ingress" {
    for_each = var.bastion_public_cidr != "" ? [1] : []
    content {
      description = "Full access from bastion host"
      from_port   = 0
      to_port     = 65535
      protocol    = "tcp"
      cidr_blocks = [var.bastion_public_cidr]
    }
  }

  dynamic "ingress" {
    for_each = var.bastion_public_cidr != "" ? [1] : []
    content {
      description = "UDP access from bastion host (DNS NLB)"
      from_port   = 0
      to_port     = 65535
      protocol    = "udp"
      cidr_blocks = [var.bastion_public_cidr]
    }
  }

  # DC6 EKS nodes live in this VPC. They need Consul RPC+gossip to join as the dc6-k8s partition.
  dynamic "ingress" {
    for_each = var.enable_k8s_partition ? [1] : []
    content {
      description = "Consul agent TCP from DC6 EKS nodes (same VPC, dc6-k8s partition)"
      from_port   = 8300
      to_port     = 8503
      protocol    = "tcp"
      cidr_blocks = [var.vpc_cidr]
    }
  }

  dynamic "ingress" {
    for_each = var.enable_k8s_partition ? [1] : []
    content {
      description = "Consul gossip UDP from DC6 EKS nodes (same VPC)"
      from_port   = 8301
      to_port     = 8302
      protocol    = "udp"
      cidr_blocks = [var.vpc_cidr]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-dc4-sg" }
}

# ── Instances ─────────────────────────────────────────────────────────────────

# DC4 Consul server — also runs mesh-gw and consul-esm (co-located to save a VM).
resource "aws_instance" "consul_server" {
  ami                         = data.aws_ami.hc_base_ubuntu.id
  instance_type               = var.consul_server_instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.dc4.id]
  associate_public_ip_address = var.enable_elastic_ip ? false : var.enable_public_ip
  key_name                    = var.ssh_key_name != "" ? var.ssh_key_name : null
  user_data                   = local.user_data_server

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
  }

  lifecycle {
    ignore_changes = [associate_public_ip_address]
  }

  tags = {
    Name = "${var.project_name}-dc4-consul-server"
    Role = "consul-server"
    DC   = "dc4-esm"
  }
}

resource "aws_eip" "consul_server" {
  count  = var.enable_elastic_ip ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.project_name}-dc4-consul-server-eip" }
}

resource "aws_eip_association" "consul_server" {
  count         = var.enable_elastic_ip ? 1 : 0
  instance_id   = aws_instance.consul_server.id
  allocation_id = aws_eip.consul_server[0].id
}

# Terminating gateway — Consul client + Envoy terminating-gw.
# Bridges Connect-aware clients to ESM-registered external services.
resource "aws_instance" "terminating_gw" {
  ami                         = data.aws_ami.hc_base_ubuntu.id
  instance_type               = var.hashicups_instance_type
  subnet_id                   = aws_subnet.public[1].id
  vpc_security_group_ids      = [aws_security_group.dc4.id]
  associate_public_ip_address = var.enable_public_ip
  key_name                    = var.ssh_key_name != "" ? var.ssh_key_name : null
  user_data                   = local.user_data_server

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
  }

  lifecycle {
    ignore_changes = [associate_public_ip_address]
  }

  tags = {
    Name = "${var.project_name}-dc4-terminating-gw"
    Role = "terminating-gw"
    DC   = "dc4-esm"
  }
}

# HashiCups service VMs — Docker only, no Consul agent.
# ESM on the server VM registers and health-checks these as external nodes.
resource "aws_instance" "hashicups" {
  for_each = local.hashicups_instances

  ami                         = data.aws_ami.hc_base_ubuntu.id
  instance_type               = var.hashicups_instance_type
  subnet_id                   = aws_subnet.public[index(local.sorted_instance_keys, each.key) % 3].id
  vpc_security_group_ids      = [aws_security_group.dc4.id]
  associate_public_ip_address = var.enable_public_ip
  key_name                    = var.ssh_key_name != "" ? var.ssh_key_name : null
  user_data                   = local.user_data_hashicups

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
  }

  tags = {
    Name     = "${var.project_name}-dc4-${each.key}"
    Role     = each.value
    Instance = each.key
    DC       = "dc4-esm"
  }
}
