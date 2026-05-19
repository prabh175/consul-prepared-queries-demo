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

  # Expand map(number) into a flat map of instance_key → service_name.
  # Single-count services keep their plain name; multi-count get a numeric suffix.
  # e.g. { "postgres" = "postgres", "product-api-1" = "product-api", ... }
  hashicups_instances = merge([
    for svc, cnt in var.hashicups_service_counts : {
      for i in range(cnt) :
      (cnt > 1 ? "${svc}-${i + 1}" : svc) => svc
    }
  ]...)

  sorted_instance_keys = sort(keys(local.hashicups_instances))

  user_data_base = <<-EOT
    #!/bin/bash
    set -euo pipefail
    apt-get update -y
    apt-get install -y docker.io
    systemctl enable --now docker
    usermod -aG docker ubuntu || true
  EOT

  user_data_dnsmasq = var.enable_consul_dns_bridge ? join("\n", [
    "",
    "apt-get install -y dnsmasq",
    "cat >/etc/dnsmasq.d/10-consul.conf <<'CFG'",
    "bind-interfaces",
    "listen-address=0.0.0.0",
    "no-resolv",
    "cache-size=0",
    "server=/consul/127.0.0.1#8600",
    "CFG",
    "systemctl enable dnsmasq",
    "systemctl restart dnsmasq",
  ]) : ""

  user_data_node_exporter = join("\n", [
    "",
    "useradd --no-create-home --shell /bin/false node_exporter 2>/dev/null || true",
    "curl -fsSL 'https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz' | tar xz -C /tmp",
    "install -m 0755 /tmp/node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/node_exporter",
    "rm -rf /tmp/node_exporter-1.8.2.linux-amd64",
    "printf '[Unit]\\nDescription=Prometheus Node Exporter\\nAfter=network-online.target\\n\\n[Service]\\nUser=node_exporter\\nExecStart=/usr/local/bin/node_exporter\\nRestart=always\\n\\n[Install]\\nWantedBy=multi-user.target\\n' > /etc/systemd/system/node_exporter.service",
    "systemctl daemon-reload",
    "systemctl enable --now node_exporter",
  ])

  user_data_consul_exporter = join("\n", [
    "",
    "useradd --no-create-home --shell /bin/false consul_exporter 2>/dev/null || true",
    "curl -fsSL 'https://github.com/prometheus/consul_exporter/releases/download/v0.13.0/consul_exporter-0.13.0.linux-amd64.tar.gz' | tar xz -C /tmp",
    "install -m 0755 /tmp/consul_exporter-0.13.0.linux-amd64/consul_exporter /usr/local/bin/consul_exporter",
    "rm -rf /tmp/consul_exporter-0.13.0.linux-amd64",
  ])

  user_data_server    = "${local.user_data_base}${local.user_data_dnsmasq}${local.user_data_node_exporter}${local.user_data_consul_exporter}"
  user_data_hashicups = "${local.user_data_base}${local.user_data_node_exporter}"
}

# ── VPC ──────────────────────────────────────────────────────────────────────

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.project_name}-vpc-dc3" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project_name}-igw-dc3" }
}

resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags = { Name = "${var.project_name}-public-dc3-${count.index + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project_name}-rt-dc3" }
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

resource "aws_security_group" "dc3" {
  name        = "${var.project_name}-dc3"
  description = "DC3 consul server + hashicups VMs"
  vpc_id      = aws_vpc.this.id

  # Intra-DC: all VMs share this SG so gossip, app ports and Envoy all route via self.
  ingress {
    description = "All TCP within DC3"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "All UDP within DC3"
    from_port   = 0
    to_port     = 65535
    protocol    = "udp"
    self        = true
  }

  # 8443: mesh-gateway; 8502-8503: Consul gRPC / gRPC-TLS (peering control plane).
  # Restricted to peer VPC CIDR when VPC peering is active, otherwise 8443 open to internet.
  ingress {
    description = "Mesh gateway"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = var.peer_vpc_id != "" ? [var.peer_vpc_cidr] : ["0.0.0.0/0"]
  }

  dynamic "ingress" {
    for_each = var.peer_vpc_id != "" ? [1] : []
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

  # DC5 EKS nodes live in this VPC. They need Consul RPC+gossip to join as the dc5-k8s partition.
  dynamic "ingress" {
    for_each = var.enable_k8s_partition ? [1] : []
    content {
      description = "Consul agent TCP from DC5 EKS nodes (same VPC, dc5-k8s partition)"
      from_port   = 8300
      to_port     = 8503
      protocol    = "tcp"
      cidr_blocks = [var.vpc_cidr]
    }
  }

  dynamic "ingress" {
    for_each = var.enable_k8s_partition ? [1] : []
    content {
      description = "Consul gossip UDP from DC5 EKS nodes (same VPC)"
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

  tags = { Name = "${var.project_name}-dc3-sg" }
}

# ── Instances ─────────────────────────────────────────────────────────────────

resource "aws_instance" "consul_server" {
  ami                         = data.aws_ami.hc_base_ubuntu.id
  instance_type               = var.consul_server_instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.dc3.id]
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
    Name = "${var.project_name}-dc3-consul-server"
    Role = "consul-server"
    DC   = "dc3-vm"
  }
}

resource "aws_eip" "consul_server" {
  count  = var.enable_elastic_ip ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.project_name}-dc3-consul-server-eip" }
}

resource "aws_eip_association" "consul_server" {
  count         = var.enable_elastic_ip ? 1 : 0
  instance_id   = aws_instance.consul_server.id
  allocation_id = aws_eip.consul_server[0].id
}

resource "aws_instance" "hashicups" {
  for_each = local.hashicups_instances

  ami                         = data.aws_ami.hc_base_ubuntu.id
  instance_type               = var.hashicups_instance_type
  subnet_id                   = aws_subnet.public[index(local.sorted_instance_keys, each.key) % 3].id
  vpc_security_group_ids      = [aws_security_group.dc3.id]
  associate_public_ip_address = var.enable_public_ip
  key_name                    = var.ssh_key_name != "" ? var.ssh_key_name : null
  user_data                   = local.user_data_hashicups

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
  }

  tags = {
    Name     = "${var.project_name}-dc3-${each.key}"
    Role     = each.value
    Instance = each.key
    DC       = "dc3-vm"
  }
}
