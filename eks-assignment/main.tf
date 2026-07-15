module "eks" {
  source = "./modules/eks"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  vpc_id             = var.vpc_id
  subnet_ids         = var.private_subnet_ids

  tags = var.tags
}

module "node_group" {
  source = "./modules/node-group"

  cluster_name    = module.eks.cluster_name
  node_group_name = var.node_group_name
  subnet_ids      = var.private_subnet_ids
  instance_type   = var.instance_type
  desired_size    = var.desired_size
  min_size        = var.min_size
  max_size        = var.max_size

  tags = var.tags
}

module "alb_controller" {
  source = "./modules/alb-controller"

  cluster_name       = module.eks.cluster_name
  oidc_provider_arn  = module.eks.oidc_provider_arn
  oidc_provider_url  = module.eks.oidc_provider_url
  vpc_id             = var.vpc_id
  aws_region         = var.aws_region
  helm_chart_version = var.alb_controller_version

  tags = var.tags

  depends_on = [module.node_group]
}
