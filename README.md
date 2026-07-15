# EKS Assignment — Private Cluster + ALB Ingress Controller

Terraform assignment: provision a private EKS 1.36 cluster with an AL2023 managed node group and deploy the AWS Load Balancer Controller via Helm using IRSA.

## Architecture

```
VPC (caller-supplied)
└── Private Subnets
    ├── EKS Control Plane (private endpoint only)
    └── Managed Node Group
        └── t3.medium · AL2023 · ON_DEMAND
            └── kube-system namespace
                └── aws-load-balancer-controller (Helm)
                    └── IRSA → ALB Controller IAM Role
```

### IRSA (IAM Roles for Service Accounts)

The ALB Controller pod assumes an IAM role without any static credentials. The flow:

1. EKS creates an OIDC provider tied to the cluster's issuer URL.
2. An IAM role is created with a trust policy that allows `sts:AssumeRoleWithWebIdentity` — scoped to the specific service account (`kube-system/aws-load-balancer-controller`).
3. Kubernetes annotates the service account with `eks.amazonaws.com/role-arn`.
4. The Pod Identity webhook injects the OIDC token; the AWS SDK exchanges it for short-lived credentials.

## Module Structure

```
eks-assignment/
├── main.tf            # Module wiring
├── variables.tf       # Input variables
├── outputs.tf         # Cluster + role outputs
├── versions.tf        # Provider versions
└── modules/
    ├── eks/           # EKS cluster + OIDC provider
    ├── node-group/    # Managed node group + node IAM role
    └── alb-controller/ # IRSA role + IAM policy + Helm release
```

## Prerequisites

| Tool | Minimum Version |
|------|----------------|
| Terraform | >= 1.5.0 |
| AWS CLI | >= 2.x |
| kubectl | >= 1.28 |
| Helm | >= 3.x |

AWS credentials must have permissions to create EKS clusters, IAM roles, security groups, and deploy Helm charts.

## Inputs

| Name | Description | Default |
|------|-------------|---------|
| `aws_region` | AWS region | `us-east-1` |
| `cluster_name` | EKS cluster name | — |
| `kubernetes_version` | Kubernetes version | `1.36` |
| `vpc_id` | VPC ID | — |
| `private_subnet_ids` | Private subnet IDs | — |
| `node_group_name` | Node group name | `main` |
| `instance_type` | EC2 instance type | `t3.medium` |
| `desired_size` | Node desired count | `1` |
| `min_size` | Node minimum count | `1` |
| `max_size` | Node maximum count | `1` |
| `alb_controller_version` | Helm chart version | `1.8.1` |
| `tags` | Resource tags | `{}` |

## Deployment

### 1. Configure backend (optional)

Add a `backend.tf` with your remote state configuration if needed.

### 2. Create `terraform.tfvars`

```hcl
cluster_name       = "my-eks-cluster"
vpc_id             = "vpc-0abc123..."
private_subnet_ids = ["subnet-0aaa...", "subnet-0bbb..."]
tags = {
  Environment = "dev"
  Owner       = "platform-eng"
}
```

### 3. Deploy

```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### 4. Configure kubectl

```bash
# Output printed after apply:
aws eks update-kubeconfig --region us-east-1 --name <cluster_name>
```

Or use the Terraform output directly:

```bash
$(terraform output -raw configure_kubectl)
```

## Validation

### Cluster access

```bash
kubectl get nodes
kubectl get pods -n kube-system
```

### ALB Controller running

```bash
kubectl get deployment aws-load-balancer-controller -n kube-system
kubectl logs -n kube-system deployment/aws-load-balancer-controller
```

### IRSA working (no credential errors in logs)

```bash
kubectl logs -n kube-system deployment/aws-load-balancer-controller | grep -i "error\|warn"
```

### Test with a sample Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: test-ingress
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/target-type: ip
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-service
                port:
                  number: 80
```

```bash
kubectl apply -f test-ingress.yaml
kubectl get ingress test-ingress
# ADDRESS field should populate with an ALB DNS name within ~60s
```

## Outputs

| Name | Description |
|------|-------------|
| `cluster_name` | EKS cluster name |
| `cluster_endpoint` | API server endpoint (sensitive) |
| `cluster_certificate_authority_data` | CA data for kubeconfig (sensitive) |
| `oidc_provider_arn` | OIDC provider ARN |
| `node_group_arn` | Managed node group ARN |
| `node_role_arn` | Node IAM role ARN |
| `alb_controller_role_arn` | ALB Controller IRSA role ARN |
| `configure_kubectl` | Shell command to configure kubectl |

## Cleanup

```bash
terraform destroy
```

> **Note:** If an ALB was provisioned by the controller (via Ingress), delete those Ingress resources first so the controller can clean up the ALBs before `terraform destroy` removes the IAM role.
