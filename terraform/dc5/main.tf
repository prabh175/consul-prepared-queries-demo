# DC5 — EKS cluster for Consul admin partition dc5-k8s.
# This cluster reuses DC3's VPC (no extra VPC peering) and connects to DC3's Consul server
# via consul-k8s externalServers. Services here are registered under partition=dc5-k8s,
# datacenter=dc3-vm, giving them full mesh capability with DC3 VM services.
#
# Consul client daemonset gossip flows: EKS node ↔ DC3 Consul server on 8300-8303.
# The enable_k8s_partition = true flag on dc3 opens the DC3 SG to allow this.

# ── IAM — EKS cluster role ────────────────────────────────────────────────────

resource "aws_iam_role" "eks_cluster" {
  name = "${var.project_name}-dc5-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.project_name}-dc5-eks-cluster-role" }
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController",
  ])
  role       = aws_iam_role.eks_cluster.name
  policy_arn = each.value
}

# ── IAM — EKS node group role ─────────────────────────────────────────────────

resource "aws_iam_role" "eks_nodes" {
  name = "${var.project_name}-dc5-eks-nodes"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.project_name}-dc5-eks-nodes-role" }
}

resource "aws_iam_role_policy_attachment" "eks_nodes" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.eks_nodes.name
  policy_arn = each.value
}

# ── EKS cluster ────────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "dc5" {
  name     = "${var.project_name}-dc5"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_version

  vpc_config {
    subnet_ids              = var.dc3_subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = true
    # Restrict public endpoint to operator laptop; nodes use private endpoint within VPC.
    public_access_cidrs     = var.operator_public_cidr != "" ? [var.operator_public_cidr] : ["0.0.0.0/0"]
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]

  tags = {
    Name = "${var.project_name}-dc5"
    DC   = "dc5-k8s"
  }
}

# ── Allow EKS nodes → DC3 Consul server (gossip + RPC) ───────────────────────
# EKS creates a cluster security group applied to all nodes. Adding inbound rules here
# lets DC3's Consul server reach EKS nodes for bidirectional gossip (serf).
# The outbound direction (EKS nodes → DC3 SG) is handled by enable_k8s_partition in dc3.

resource "aws_security_group_rule" "eks_consul_tcp" {
  type              = "ingress"
  description       = "Consul RPC+gossip TCP from DC3 VMs"
  from_port         = 8300
  to_port           = 8503
  protocol          = "tcp"
  security_group_id = aws_eks_cluster.dc5.vpc_config[0].cluster_security_group_id
  cidr_blocks       = [var.dc3_vpc_cidr]
}

resource "aws_security_group_rule" "eks_consul_gossip_udp" {
  type              = "ingress"
  description       = "Consul gossip UDP from DC3 VMs"
  from_port         = 8301
  to_port           = 8302
  protocol          = "udp"
  security_group_id = aws_eks_cluster.dc5.vpc_config[0].cluster_security_group_id
  cidr_blocks       = [var.dc3_vpc_cidr]
}

# Mesh gateway: Envoy listens on 8443. Open from DC3 VPC so DC3 Consul server can
# route cross-partition traffic through the mesh gateway.
resource "aws_security_group_rule" "eks_mesh_gw" {
  type              = "ingress"
  description       = "Consul mesh gateway (Envoy) from DC3 VPC"
  from_port         = 8443
  to_port           = 8443
  protocol          = "tcp"
  security_group_id = aws_eks_cluster.dc5.vpc_config[0].cluster_security_group_id
  cidr_blocks       = [var.dc3_vpc_cidr]
}

# EKS API server (443) from DC3 VPC. The DC3 Consul server calls the Kubernetes
# TokenReview API to validate service-account JWTs for the consul-k8s auth methods
# (ACL login). DC3 resolves the cluster endpoint to the private ENIs, so it needs
# 443 ingress on the cluster security group. Without this, ACL login hangs and the
# connect-injector/clients never become ready.
resource "aws_security_group_rule" "eks_api_from_dc3" {
  type              = "ingress"
  description       = "EKS API 443 from DC3 VPC (Consul server tokenreview)"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_eks_cluster.dc5.vpc_config[0].cluster_security_group_id
  cidr_blocks       = [var.dc3_vpc_cidr]
}

# ── EKS managed node group ────────────────────────────────────────────────────

resource "aws_eks_node_group" "dc5" {
  cluster_name    = aws_eks_cluster.dc5.name
  node_group_name = "${var.project_name}-dc5-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.dc3_subnet_ids

  instance_types = [var.node_instance_type]

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 2
  }

  # SSH access for debugging. Remove in production.
  dynamic "remote_access" {
    for_each = var.ssh_key_name != "" ? [1] : []
    content {
      ec2_ssh_key = var.ssh_key_name
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_nodes,
    aws_eks_cluster.dc5,
  ]

  tags = {
    Name = "${var.project_name}-dc5-node"
    DC   = "dc5-k8s"
  }
}
