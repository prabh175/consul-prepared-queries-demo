# DC6 — EKS cluster for Consul admin partition dc6-k8s (catalog sync only).
# Reuses DC4's VPC. Consul clients are deployed as a daemonset so services are
# automatically catalog-synced into DC4's Consul. No mesh/sidecar injection.
# DC6 forms a sameness group with DC4's default partition for Scenario C failover.

# ── IAM — EKS cluster role ────────────────────────────────────────────────────

resource "aws_iam_role" "eks_cluster" {
  name = "${var.project_name}-dc6-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.project_name}-dc6-eks-cluster-role" }
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
  name = "${var.project_name}-dc6-eks-nodes"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.project_name}-dc6-eks-nodes-role" }
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

resource "aws_eks_cluster" "dc6" {
  name     = "${var.project_name}-dc6"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_version

  vpc_config {
    subnet_ids             = var.dc4_subnet_ids
    endpoint_public_access = true
    public_access_cidrs    = var.operator_public_cidr != "" ? [var.operator_public_cidr] : ["0.0.0.0/0"]
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]

  tags = {
    Name = "${var.project_name}-dc6"
    DC   = "dc6-k8s"
  }
}

# ── Allow EKS nodes ↔ DC4 Consul server (gossip + RPC) ───────────────────────
# Required for Consul client daemonset on DC6 nodes to join the DC4 Consul cluster.
# The outbound direction is covered by enable_k8s_partition = true on dc4.

resource "aws_security_group_rule" "eks_consul_tcp" {
  type              = "ingress"
  description       = "Consul RPC+gossip TCP from DC4 VMs"
  from_port         = 8300
  to_port           = 8503
  protocol          = "tcp"
  security_group_id = aws_eks_cluster.dc6.vpc_config[0].cluster_security_group_id
  cidr_blocks       = [var.dc4_vpc_cidr]
}

resource "aws_security_group_rule" "eks_consul_gossip_udp" {
  type              = "ingress"
  description       = "Consul gossip UDP from DC4 VMs"
  from_port         = 8301
  to_port           = 8302
  protocol          = "udp"
  security_group_id = aws_eks_cluster.dc6.vpc_config[0].cluster_security_group_id
  cidr_blocks       = [var.dc4_vpc_cidr]
}

# ── EKS managed node group ────────────────────────────────────────────────────

resource "aws_eks_node_group" "dc6" {
  cluster_name    = aws_eks_cluster.dc6.name
  node_group_name = "${var.project_name}-dc6-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = var.dc4_subnet_ids

  instance_types = [var.node_instance_type]

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }

  dynamic "remote_access" {
    for_each = var.ssh_key_name != "" ? [1] : []
    content {
      ec2_ssh_key = var.ssh_key_name
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_nodes,
    aws_eks_cluster.dc6,
  ]

  tags = {
    Name = "${var.project_name}-dc6-node"
    DC   = "dc6-k8s"
  }
}
