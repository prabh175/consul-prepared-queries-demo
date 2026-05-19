variable "enable_bastion" {
  type        = bool
  default     = false
  description = "Provision a bastion VM for the dual-DC DNS failover demo. After provisioning, run vm/scripts/bootstrap-bastion.sh to configure systemd-resolved with both DC NLB IPs."
}

resource "aws_instance" "bastion" {
  count = var.enable_bastion ? 1 : 0

  ami                         = data.aws_ami.hc_base_ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.dc3.id]
  associate_public_ip_address = false
  key_name                    = var.ssh_key_name != "" ? var.ssh_key_name : null

  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    apt-get update -y
    apt-get install -y dnsutils curl
  EOT

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  tags = {
    Name = "${var.project_name}-dc3-bastion"
    Role = "bastion"
    DC   = "dc3-vm"
  }

  lifecycle {
    ignore_changes = [associate_public_ip_address]
  }
}

resource "aws_eip" "bastion" {
  count  = var.enable_bastion ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.project_name}-dc3-bastion-eip" }
}

resource "aws_eip_association" "bastion" {
  count         = var.enable_bastion ? 1 : 0
  instance_id   = aws_instance.bastion[0].id
  allocation_id = aws_eip.bastion[0].id
}

output "bastion_public_ip" {
  description = "Bastion public IP (same as EIP). Set as bastion_public_cidr = \"<IP>/32\" in both dc3 and dc4 terraform.tfvars."
  value       = var.enable_bastion ? aws_eip.bastion[0].public_ip : ""
}

output "bastion_eip" {
  description = "Bastion Elastic IP allocation — stable across stop/start."
  value       = var.enable_bastion ? aws_eip.bastion[0].public_ip : ""
}
