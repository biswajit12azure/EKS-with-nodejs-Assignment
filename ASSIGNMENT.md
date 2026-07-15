# EKS End-to-End Assignment
## Provision a Private EKS Cluster and Deploy a Node.js Application with a Full CI/CD Pipeline

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Part 1 — Provision EKS Infrastructure (Terraform)](#3-part-1--provision-eks-infrastructure-terraform)
4. [Part 2 — Node.js Application](#4-part-2--nodejs-application)
5. [Part 3 — Dockerization](#5-part-3--dockerization)
6. [Part 4 — CI Pipeline: Build & Push to ECR (Jenkins)](#6-part-4--ci-pipeline-build--push-to-ecr-jenkins)
7. [Part 5 — Kubernetes Manifests](#7-part-5--kubernetes-manifests)
8. [Part 6 — CD Pipeline: Deploy to EKS (Jenkins)](#8-part-6--cd-pipeline-deploy-to-eks-jenkins)
9. [End-to-End Flow](#9-end-to-end-flow)
10. [Validation Checklist](#10-validation-checklist)
11. [Cleanup](#11-cleanup)

---

## 1. Architecture Overview

```
Developer pushes code
        │
        ▼
   Git Repository
   (GitHub / Bitbucket)
        │
        ▼
  Jenkins CI Pipeline
  ┌─────────────────────────┐
  │ 1. npm install + test   │
  │ 2. docker build         │
  │ 3. docker push → ECR    │
  └────────────┬────────────┘
               │ IMAGE_TAG
               ▼
  Jenkins CD Pipeline
  ┌─────────────────────────┐
  │ 1. aws eks update-kubeconfig │
  │ 2. kubectl apply manifests   │
  │ 3. rollout verify            │
  │ 4. smoke test → /health      │
  └────────────┬────────────┘
               │
               ▼
  ┌─────────────────────────────────┐
  │         AWS VPC                 │
  │  ┌──────────────────────────┐   │
  │  │  Private Subnets          │   │
  │  │  ┌────────────────────┐  │   │
  │  │  │  EKS Control Plane │  │   │
  │  │  │  (private endpoint)│  │   │
  │  │  └────────────────────┘  │   │
  │  │  ┌────────────────────┐  │   │
  │  │  │  Managed Node Group│  │   │
  │  │  │  t3.medium AL2023  │  │   │
  │  │  │  ┌──────────────┐  │  │   │
  │  │  │  │ hello-world  │  │  │   │
  │  │  │  │ -api Pod x2  │  │  │   │
  │  │  │  └──────────────┘  │  │   │
  │  │  └────────────────────┘  │   │
  │  └──────────────────────────┘   │
  │                                 │
  │  ┌──────────────────────────┐   │
  │  │  ALB (internet-facing)   │   │◄── Public traffic
  │  │  Provisioned by ALB      │   │    HTTP :80
  │  │  Ingress Controller      │   │
  │  └──────────────────────────┘   │
  └─────────────────────────────────┘
```

### Key Design Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| EKS endpoint | Private only | No public API server exposure |
| Node AMI | AL2023 | AWS-recommended, security patched |
| Node capacity | ON_DEMAND | Predictable cost for assignment |
| ALB scheme | internet-facing | Public access for testing |
| ALB target type | IP | Route directly to pod IPs (no NodePort hop) |
| IAM auth for ALB Controller | IRSA | No static credentials in pods |
| Docker base image | node:20-alpine | Minimal attack surface |
| Container user | Non-root | Security best practice |

---

## 2. Prerequisites

### Tools

| Tool | Minimum Version | Install |
|------|----------------|---------|
| Terraform | >= 1.5.0 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | >= 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| kubectl | >= 1.28 | https://kubernetes.io/docs/tasks/tools/ |
| Helm | >= 3.x | https://helm.sh/docs/intro/install/ |
| Docker | >= 24 | https://docs.docker.com/get-docker/ |
| Node.js | >= 18 | https://nodejs.org/ |
| Jenkins | >= 2.400 | https://www.jenkins.io/doc/book/installing/ |

### AWS Permissions

Your AWS IAM user/role needs permissions for:
- EKS (create/describe cluster, node groups)
- EC2 (VPCs, subnets, security groups)
- IAM (create roles, policies, OIDC providers)
- ECR (create repo, push images)
- ELB (create/describe ALBs — delegated to ALB Controller via IRSA)

### Existing AWS Resources Required

- **VPC** with at least 2 private subnets in different AZs
- **AWS credentials** configured locally: `aws configure`

---

## 3. Part 1 — Provision EKS Infrastructure (Terraform)

**Files:** `eks-assignment/`

### 3.1 Module Structure

```
eks-assignment/
├── main.tf              # Wires together all three modules
├── variables.tf         # All input variables with defaults
├── outputs.tf           # Cluster endpoint, OIDC ARN, kubectl command
├── versions.tf          # Provider version pins
└── modules/
    ├── eks/             # EKS cluster + cluster IAM role + OIDC provider
    ├── node-group/      # Managed node group + node IAM role (AL2023, ON_DEMAND)
    └── alb-controller/  # IRSA role + IAM policy + Helm release
```

### 3.2 What Gets Created

**`modules/eks`**
- `aws_eks_cluster` — Kubernetes 1.36, private endpoint only, control plane logging enabled
- `aws_iam_role` — cluster role with `AmazonEKSClusterPolicy` + `AmazonEKSVPCResourceController`
- `aws_security_group` — cluster control plane SG
- `aws_iam_openid_connect_provider` — OIDC provider (required for IRSA)

**`modules/node-group`**
- `aws_eks_node_group` — AL2023, t3.medium, ON_DEMAND, min/desired/max = 1
- `aws_iam_role` — node role with `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`

**`modules/alb-controller`**
- `aws_iam_role` — IRSA role scoped to `kube-system/aws-load-balancer-controller` service account
- `aws_iam_policy` — full ALB Controller permissions (EC2 describe, ELB create/manage, WAF, ACM)
- `helm_release` — `aws-load-balancer-controller` chart from `https://aws.github.io/eks-charts`

### 3.3 IRSA Explained

IRSA (IAM Roles for Service Accounts) lets a Kubernetes pod assume an AWS IAM role without any static credentials:

```
Pod starts
  └── Kubernetes injects OIDC JWT token into pod via projected volume
        └── AWS SDK calls STS AssumeRoleWithWebIdentity
              └── STS validates token against EKS OIDC provider
                    └── Returns short-lived credentials
                          └── ALB Controller can now call AWS APIs
```

The IAM trust policy scopes the role to one specific service account:
```json
"Condition": {
  "StringEquals": {
    "<oidc-provider>:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller",
    "<oidc-provider>:aud": "sts.amazonaws.com"
  }
}
```

### 3.4 Create `terraform.tfvars`

```hcl
cluster_name       = "my-eks-cluster"
vpc_id             = "vpc-0abc123def456"
private_subnet_ids = ["subnet-0aaa111", "subnet-0bbb222"]

tags = {
  Environment = "dev"
  Owner       = "platform-eng"
  Assignment  = "eks-end-to-end"
}
```

### 3.5 Deploy

```bash
cd eks-assignment/

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Expected output after apply:
```
cluster_name                   = "my-eks-cluster"
cluster_endpoint               = <sensitive>
oidc_provider_arn              = "arn:aws:iam::123456789012:oidc-provider/..."
configure_kubectl              = "aws eks update-kubeconfig --region us-east-1 --name my-eks-cluster"
```

### 3.6 Configure kubectl

```bash
$(terraform output -raw configure_kubectl)

# Verify
kubectl get nodes
kubectl get pods -n kube-system
```

You should see the ALB Controller pod running:
```
NAME                                            READY   STATUS    RESTARTS
aws-load-balancer-controller-xxxxxxxxxx-xxxxx   1/1     Running   0
```

---

## 4. Part 2 — Node.js Application

**Files:** `app-deployment-assignment/app/`

### 4.1 Application Structure

```
app/
├── src/
│   ├── index.js          # Express app, exports app for testing
│   └── routes/
│       ├── health.js     # GET /health
│       └── users.js      # GET /users, GET /users/:id
├── src/__tests__/
│   └── app.test.js       # Jest tests (supertest)
└── package.json
```

### 4.2 API Endpoints

| Method | Path | Response |
|--------|------|----------|
| GET | `/` | `{ "message": "Hello World from EKS!", "version": "1.0.0" }` |
| GET | `/health` | `{ "status": "healthy", "uptime": 123.4, "timestamp": "..." }` |
| GET | `/users` | `{ "users": [{ "id": 1, "name": "Alice", "role": "admin" }, ...] }` |
| GET | `/users/:id` | `{ "user": { "id": 1, ... } }` or `404` |

### 4.3 Run Locally

```bash
cd app-deployment-assignment/app

npm install
npm start       # http://localhost:3000

# Test endpoints
curl http://localhost:3000/health
curl http://localhost:3000/users
curl http://localhost:3000/users/1

# Run tests
npm test
```

### 4.4 Push Source Code to Git

```bash
# GitHub example
git init
git remote add origin https://github.com/<your-org>/hello-world-api.git
git add .
git commit -m "feat: Initial Node.js REST API"
git push -u origin main
```

> **Note:** The Jenkins CI pipeline will pull from this repo. Set the repository URL in your Jenkins job configuration.

---

## 5. Part 3 — Dockerization

**File:** `app-deployment-assignment/Dockerfile`

### 5.1 Dockerfile Explained

```dockerfile
# Stage 1: Install production deps
FROM node:20-alpine AS builder
WORKDIR /app
COPY app/package*.json ./
RUN npm ci --only=production
COPY app/src ./src

# Stage 2: Minimal production image
FROM node:20-alpine AS production
ENV NODE_ENV=production PORT=3000
WORKDIR /app
RUN addgroup -S appgroup && adduser -S appuser -G appgroup  # non-root
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/src ./src
COPY app/package.json ./
USER appuser
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://localhost:3000/health || exit 1
CMD ["node", "src/index.js"]
```

**Why two stages?** The `builder` stage has dev tooling; only the final artifacts copy into the `production` stage. The resulting image contains no build tools — smaller and more secure.

### 5.2 Build & Test Locally

```bash
cd app-deployment-assignment/

# Build
docker build -t hello-world-api:local .

# Run
docker run -p 3000:3000 hello-world-api:local

# Verify health check
curl http://localhost:3000/health
# Expected: {"status":"healthy","uptime":2.1,"timestamp":"..."}

# Check image size
docker images hello-world-api:local
```

### 5.3 Create ECR Repository

Before the CI pipeline can push, create the ECR repo manually (or let the CI pipeline create it automatically):

```bash
aws ecr create-repository \
  --repository-name hello-world-api \
  --region us-east-1 \
  --image-scanning-configuration scanOnPush=true
```

---

## 6. Part 4 — CI Pipeline: Build & Push to ECR (Jenkins)

**File:** `app-deployment-assignment/jenkins/Jenkinsfile-CI`

### 6.1 Pipeline Stages

```
Checkout → Install Dependencies → Run Tests → Build Docker Image → Push to ECR
```

| Stage | Command | Notes |
|-------|---------|-------|
| Checkout | `checkout scm` | Pulls from configured Git repo |
| Install | `npm ci` | Clean install from lockfile |
| Test | `npm test` | Jest; JUnit results published |
| Docker Build | `docker build` | Tags with `<short-commit-sha>` + `latest` |
| ECR Push | `docker push` | Creates repo if missing; pushes both tags |

### 6.2 Jenkins Setup

**Step 1 — Install required plugins:**
- Pipeline
- AWS Credentials Plugin
- JUnit Plugin

**Step 2 — Add AWS credentials:**
1. Jenkins → Manage Jenkins → Credentials → (global) → Add Credentials
2. Kind: **AWS Credentials**
3. ID: `aws-credentials`
4. Enter your Access Key ID and Secret Access Key

**Step 3 — Create a Pipeline job:**
1. New Item → Pipeline
2. Pipeline → Definition: **Pipeline script from SCM**
3. SCM: Git → enter your repo URL
4. Script Path: `app-deployment-assignment/jenkins/Jenkinsfile-CI`

**Step 4 — Set environment variables** (job → Configure → Environment variables or as global env vars):

```
AWS_ACCOUNT_ID  = 123456789012
AWS_REGION      = us-east-1
ECR_REPO_NAME   = hello-world-api
```

### 6.3 What Gets Archived

On success, the pipeline writes `image_tag.txt` containing the short commit SHA (e.g. `fd6ea43`). The CD pipeline reads this as the `IMAGE_TAG` parameter.

---

## 7. Part 5 — Kubernetes Manifests

**Files:** `app-deployment-assignment/k8s/`

### 7.1 deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-world-api
spec:
  replicas: 2                          # Two pods for HA
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0                # Zero-downtime deploys
  template:
    spec:
      containers:
        - name: hello-world-api
          image: <ecr-uri>:<tag>       # Patched by CD pipeline
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 250m, memory: 256Mi }
          livenessProbe:               # Restart pod if unhealthy
            httpGet: { path: /health, port: 3000 }
          readinessProbe:              # Remove from LB if not ready
            httpGet: { path: /health, port: 3000 }
```

### 7.2 service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: hello-world-api
spec:
  type: ClusterIP      # Internal only — ALB routes to pods directly via IP
  selector:
    app: hello-world-api
  ports:
    - port: 80
      targetPort: 3000
```

### 7.3 ingress.yaml (ALB)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing     # Public ALB
    alb.ingress.kubernetes.io/target-type: ip             # Route to pod IPs
    alb.ingress.kubernetes.io/healthcheck-path: /health
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hello-world-api
                port:
                  number: 80
```

When you apply this Ingress, the ALB Controller (deployed in Part 1) reads the annotations and provisions a real AWS ALB. The `ADDRESS` field populates with a DNS name within ~60 seconds.

### 7.4 Deploy Manually (without Jenkins)

```bash
# Substitute your image URI first
IMAGE="123456789012.dkr.ecr.us-east-1.amazonaws.com/hello-world-api:abc1234"
sed -i "s|ACCOUNT_ID.dkr.ecr.REGION.amazonaws.com/hello-world-api:latest|$IMAGE|g" \
  k8s/deployment.yaml

kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml

# Watch rollout
kubectl rollout status deployment/hello-world-api

# Get ALB DNS
kubectl get ingress hello-world-api
# NAME              CLASS   HOSTS   ADDRESS                                     PORTS
# hello-world-api   <none>  *       k8s-default-xxxx.us-east-1.elb.amazonaws.com   80

# Test
curl http://<ALB-DNS>/health
curl http://<ALB-DNS>/users
```

---

## 8. Part 6 — CD Pipeline: Deploy to EKS (Jenkins)

**File:** `app-deployment-assignment/jenkins/Jenkinsfile-CD`

### 8.1 Pipeline Stages

```
Checkout → Configure kubectl → Patch Image Tag → kubectl apply → Verify Rollout → Smoke Test
```

| Stage | What happens |
|-------|-------------|
| Configure kubectl | `aws eks update-kubeconfig` using AWS credentials |
| Patch Image Tag | `sed` replaces placeholder in `deployment.yaml` with real ECR URI + tag |
| Apply Manifests | `kubectl apply` for deployment, service, ingress |
| Verify Rollout | `kubectl rollout status --timeout=180s` — waits for pods to be ready |
| Smoke Test | Polls `GET /health` on ALB DNS every 10s, passes on first HTTP 200 |
| On Failure | Automatically runs `kubectl rollout undo` to revert to previous image |

### 8.2 Jenkins Setup

**Additional env vars** (beyond CI):

```
EKS_CLUSTER_NAME  = my-eks-cluster
K8S_NAMESPACE     = default
```

**Create a separate Pipeline job:**
1. New Item → Pipeline → name it `hello-world-api-CD`
2. Script Path: `app-deployment-assignment/jenkins/Jenkinsfile-CD`
3. Check **"This project is parameterized"** → Add String Parameter:
   - Name: `IMAGE_TAG`, Default: `latest`

### 8.3 Chain CI → CD Automatically

Add this to `Jenkinsfile-CI` in the `post { success }` block:

```groovy
post {
    success {
        // ... existing archiveArtifacts ...
        build job: 'hello-world-api-CD',
              parameters: [string(name: 'IMAGE_TAG', value: "${IMAGE_TAG}")]
    }
}
```

This triggers the CD pipeline automatically after every successful CI run, passing the exact image tag that was built and tested.

---

## 9. End-to-End Flow

```
1. Developer pushes code to Git
         │
         ▼
2. Jenkins CI triggers (webhook or polling)
   ├── npm ci
   ├── npm test  ──────────────────────── FAIL → stop, notify
   ├── docker build -t <ecr>:<sha>
   └── docker push → ECR
         │
         ▼ IMAGE_TAG = <short-sha>
3. Jenkins CD triggers (parameterized build from CI)
   ├── aws eks update-kubeconfig
   ├── sed: patch deployment.yaml image tag
   ├── kubectl apply -f k8s/
   ├── kubectl rollout status ──────────── FAIL → kubectl rollout undo
   └── curl /health on ALB DNS ─────────── FAIL → kubectl rollout undo
         │
         ▼
4. Traffic hits ALB → pods serve requests
   GET /           → {"message": "Hello World from EKS!"}
   GET /health     → {"status": "healthy"}
   GET /users      → [{"id":1,"name":"Alice"}, ...]
```

---

## 10. Validation Checklist

### Infrastructure (Part 1)

```bash
# Cluster is up and private
aws eks describe-cluster --name my-eks-cluster \
  --query 'cluster.resourcesVpcConfig.{private:endpointPrivateAccess,public:endpointPublicAccess}'
# Expected: {"private": true, "public": false}

# Nodes are ready
kubectl get nodes
# NAME                STATUS   ROLES    AGE   VERSION
# ip-10-0-x-x...     Ready    <none>   5m    v1.36.x

# ALB Controller is running
kubectl get deployment aws-load-balancer-controller -n kube-system
# READY 1/1

# IRSA is working (no AWS credential errors in logs)
kubectl logs -n kube-system deployment/aws-load-balancer-controller | grep -i error
```

### Application (Parts 2–3)

```bash
# Image exists in ECR
aws ecr list-images --repository-name hello-world-api --region us-east-1

# Container runs and passes health check
docker run --rm -p 3000:3000 <ecr-image>:<tag>
curl http://localhost:3000/health   # {"status":"healthy",...}
```

### Kubernetes Deployment (Part 5)

```bash
# All pods running
kubectl get pods -l app=hello-world-api
# NAME                             READY   STATUS    RESTARTS
# hello-world-api-xxxxx-aaaaa      1/1     Running   0
# hello-world-api-xxxxx-bbbbb      1/1     Running   0

# ALB provisioned
kubectl get ingress hello-world-api
# ADDRESS should be a *.elb.amazonaws.com hostname

ALB=$(kubectl get ingress hello-world-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl http://$ALB/
curl http://$ALB/health
curl http://$ALB/users
curl http://$ALB/users/1
curl http://$ALB/users/999   # Should return 404
```

### CI/CD (Parts 4 & 6)

- Jenkins CI job builds green after a code push
- ECR shows a new image tagged with the commit SHA
- Jenkins CD deploys the new image — pods restart with `kubectl rollout status` passing
- `GET /health` returns HTTP 200 via ALB after deploy

---

## 11. Cleanup

### Remove Kubernetes resources first

> This is important — delete Ingress before destroying Terraform, otherwise the ALB Controller cannot clean up the ALB and `terraform destroy` will fail waiting on the security group.

```bash
kubectl delete ingress hello-world-api
kubectl delete service hello-world-api
kubectl delete deployment hello-world-api

# Confirm ALB is gone in AWS console before proceeding
```

### Destroy infrastructure

```bash
cd eks-assignment/
terraform destroy
```

### Delete ECR images

```bash
aws ecr delete-repository \
  --repository-name hello-world-api \
  --region us-east-1 \
  --force
```
