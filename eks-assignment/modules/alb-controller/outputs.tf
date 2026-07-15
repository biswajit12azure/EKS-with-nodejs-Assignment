output "alb_controller_role_arn" {
  description = "ARN of the IAM role used by the ALB Controller"
  value       = aws_iam_role.alb_controller.arn
}

output "alb_controller_policy_arn" {
  description = "ARN of the IAM policy attached to the ALB Controller role"
  value       = aws_iam_policy.alb_controller.arn
}

output "helm_release_status" {
  description = "Status of the Helm release"
  value       = helm_release.alb_controller.status
}
