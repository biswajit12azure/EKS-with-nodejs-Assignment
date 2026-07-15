output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate authority data"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider — use this for additional IRSA roles"
  value       = module.eks.oidc_provider_arn
}

output "node_group_arn" {
  description = "ARN of the managed node group"
  value       = module.node_group.node_group_arn
}

output "node_role_arn" {
  description = "ARN of the IAM role used by worker nodes"
  value       = module.node_group.node_role_arn
}

output "alb_controller_role_arn" {
  description = "ARN of the IRSA role for the AWS Load Balancer Controller"
  value       = module.alb_controller.role_arn
}

output "configure_kubectl" {
  description = "Run this command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
