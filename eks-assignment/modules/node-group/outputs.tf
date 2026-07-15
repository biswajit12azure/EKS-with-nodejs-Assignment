output "node_group_id" {
  description = "ID of the managed node group"
  value       = aws_eks_node_group.this.id
}

output "node_group_arn" {
  description = "ARN of the managed node group"
  value       = aws_eks_node_group.this.arn
}

output "node_group_status" {
  description = "Current status of the managed node group"
  value       = aws_eks_node_group.this.status
}

output "node_role_arn" {
  description = "ARN of the IAM role used by worker nodes"
  value       = aws_iam_role.node.arn
}
