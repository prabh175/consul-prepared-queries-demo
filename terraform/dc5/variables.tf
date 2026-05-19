# DC5 — EKS cluster, Consul admin partition dc5-k8s, partition of DC3 (dc3-vm datacenter).
# Reuses DC3's VPC so no VPC peering is needed between DC3 and DC5.

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "consul-pq-demo"
}

# ── DC3 parent datacenter references ──────────────────────────────────────────
# Copy these from: terraform -chdir=terraform/dc3 output

variable "dc3_vpc_id" {
  type        = string
  description = "DC3 VPC ID. terraform -chdir=terraform/dc3 output -raw vpc_id"
}

variable "dc3_vpc_cidr" {
  type        = string
  default     = "10.10.0.0/16"
  description = "DC3 VPC CIDR. terraform -chdir=terraform/dc3 output -raw vpc_cidr"
}

variable "dc3_subnet_ids" {
  type        = list(string)
  description = "DC3 public subnet IDs (3 AZs). terraform -chdir=terraform/dc3 output -json subnet_ids | jq -r '.[]'"
}

variable "dc3_security_group_id" {
  type        = string
  description = "DC3 SG ID. terraform -chdir=terraform/dc3 output -raw security_group_id"
}

# ── EKS cluster settings ───────────────────────────────────────────────────────

variable "eks_version" {
  type    = string
  default = "1.32"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
  description = "EKS node instance type. t3.medium gives 2 vCPU / 4 GB — enough for consul-k8s + hashicups pods."
}

variable "operator_public_cidr" {
  type        = string
  default     = ""
  description = "Operator laptop IP/32. Opens kubectl API server access from outside the VPC."
}

variable "ssh_key_name" {
  type    = string
  default = ""
  description = "EC2 key pair name for SSH access to EKS nodes (optional)."
}
