output "cluster_name" {
  description = "EKS cluster name. Use with: aws eks update-kubeconfig --name <name>"
  value       = aws_eks_cluster.dc5.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.dc5.endpoint
}

output "cluster_security_group_id" {
  description = "EKS cluster security group ID. Consul agent SG rules are added to this."
  value       = aws_eks_cluster.dc5.vpc_config[0].cluster_security_group_id
}

output "kubeconfig_hint" {
  description = "Run this to configure kubectl for DC5."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.dc5.name} --alias dc5"
}
