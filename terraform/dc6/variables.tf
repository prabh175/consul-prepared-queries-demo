# DC6 — EKS cluster, Consul admin partition dc6-k8s, partition of DC4 (dc4-esm datacenter).
# Catalog sync only — no connect inject, no mesh gateways, no sidecar proxies.
# Services registered here are catalog-synced into DC4's Consul so they can participate
# in the sameness group for Scenario C failover (DC4 VM → DC6 K8s).

variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "project_name" {
  type    = string
  default = "consul-pq-demo"
}

# ── DC4 parent datacenter references ──────────────────────────────────────────
# Copy these from: terraform -chdir=terraform/dc4 output

variable "dc4_vpc_id" {
  type        = string
  description = "DC4 VPC ID. terraform -chdir=terraform/dc4 output -raw vpc_id"
}

variable "dc4_vpc_cidr" {
  type        = string
  default     = "10.20.0.0/16"
  description = "DC4 VPC CIDR. terraform -chdir=terraform/dc4 output -raw vpc_cidr"
}

variable "dc4_subnet_ids" {
  type        = list(string)
  description = "DC4 public subnet IDs (3 AZs). terraform -chdir=terraform/dc4 output -json subnet_ids | jq -r '.[]'"
}

variable "dc4_security_group_id" {
  type        = string
  description = "DC4 SG ID. terraform -chdir=terraform/dc4 output -raw security_group_id"
}

# ── EKS cluster settings ───────────────────────────────────────────────────────

variable "eks_version" {
  type    = string
  default = "1.32"
}

variable "node_instance_type" {
  type        = string
  default     = "t3.small"
  description = "EKS node instance type. t3.small (2 vCPU / 2 GB) is sufficient for catalog sync — no sidecars."
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
