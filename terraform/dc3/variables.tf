variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "consul-pq-demo"
}

variable "vpc_cidr" {
  type        = string
  default     = "10.10.0.0/16"
  description = "CIDR for the DC3 VPC. Must not overlap with DC4 (10.20.0.0/16)."
}

variable "ssh_key_name" {
  type    = string
  default = ""
}

variable "operator_public_cidr" {
  type        = string
  description = "Operator laptop IP in CIDR notation (e.g. 1.2.3.4/32). Opens all ports on all VMs."
  default     = ""
}

variable "bastion_public_cidr" {
  type        = string
  description = "Bastion host public IP in CIDR notation. Opens all ports on all VMs. Leave empty if unused."
  default     = ""
}

variable "vm_arch" {
  type    = string
  default = "amd64"
  validation {
    condition     = contains(["amd64", "arm64"], var.vm_arch)
    error_message = "Must be amd64 or arm64."
  }
}

variable "consul_server_instance_type" {
  type    = string
  default = "t3.small"
}

variable "hashicups_instance_type" {
  type    = string
  default = "t3.micro"
}

# map of service → instance count. product-api = 3 for the failover demo.
variable "hashicups_service_counts" {
  type = map(number)
  default = {
    postgres    = 1
    product-api = 3
    payments    = 1
    public-api  = 1
    frontend    = 1
  }
}

variable "root_volume_size_gb" {
  type    = number
  default = 20
}

variable "enable_public_ip" {
  type    = bool
  default = true
}

variable "route53_public_zone_name" {
  type    = string
  default = ""
}

variable "enable_consul_dns_bridge" {
  type    = bool
  default = true
}

variable "peer_vpc_id" {
  type        = string
  default     = ""
  description = "DC4 VPC ID. Set after applying dc4 to enable VPC peering."
}

variable "peer_vpc_cidr" {
  type        = string
  default     = "10.20.0.0/16"
  description = "DC4 VPC CIDR. Used for routing and security group rules."
}

variable "peer_region" {
  type        = string
  default     = "us-west-2"
  description = "AWS region where DC4 lives."
}

variable "enable_elastic_ip" {
  type        = bool
  default     = false
  description = "Attach an Elastic IP to the Consul server VM for a stable DNS endpoint. Use in dnsmasq-dual-dc.conf."
}

variable "enable_k8s_partition" {
  type        = bool
  default     = false
  description = "Open Consul agent ports (8300-8503 TCP, 8301-8302 UDP) from the VPC CIDR so DC5 EKS worker nodes can join the Consul cluster as the dc5-k8s admin partition."
}
