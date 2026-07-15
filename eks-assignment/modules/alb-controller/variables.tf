variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC identity provider"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the OIDC identity provider (includes https://)"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC where the cluster is deployed"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "helm_chart_version" {
  description = "Version of the aws-load-balancer-controller Helm chart"
  type        = string
  default     = "1.8.1"
}

variable "tags" {
  type    = map(string)
  default = {}
}
