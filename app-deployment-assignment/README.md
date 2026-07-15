# App Deployment on EKS — Assignment

End-to-end assignment: build a Node.js REST API, containerize it, push to ECR via Jenkins CI, and deploy to a private EKS cluster using Kubernetes manifests + ALB Ingress Controller.

## Repository Structure

```
app-deployment-assignment/
├── app/                        # Node.js REST API source
│   ├── src/
│   │   ├── index.js            # Express app entry point
│   │   └── routes/
│   │       ├── health.js       # GET /health
│   │       └── users.js        # GET /users, GET /users/:id
│   ├── src/__tests__/
│   │   └── app.test.js         # Jest unit + integration tests
│   ├── package.json
│   └── .gitignore
├── Dockerfile                  # Multi-stage build (node:20-alpine)
├── .dockerignore
├── k8s/
│   ├── deployment.yaml         # 2-replica Deployment with liveness/readiness probes
│   ├── service.yaml            # ClusterIP Service
│   └── ingress.yaml            # ALB Ingress (internet-facing)
└── jenkins/
    ├── Jenkinsfile-CI          # CI: install → test → docker build → ECR push
    └── Jenkinsfile-CD          # CD: kubectl apply → rollout verify → smoke test
```

---

## Part 1 — Node.js Application

### API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Hello World + version |
| GET | `/health` | Liveness check — returns `status: healthy` + uptime |
| GET | `/users` | List all users |
| GET | `/users/:id` | Get single user by ID |

### Run Locally

```bash
cd app
npm install
npm start          # http://localhost:3000
npm test           # Jest tests with coverage
```

---

## Part 2 — Dockerization

### Build & Run

```bash
# Build
docker build -t hello-world-api:local .

# Run
docker run -p 3000:3000 hello-world-api:local

# Test
curl http://localhost:3000/health
```

The Dockerfile uses a two-stage build:
- **Stage 1 (`builder`)**: installs production dependencies
- **Stage 2 (`production`)**: minimal runtime image, runs as non-root user, includes `HEALTHCHECK`

---

## Part 3 — CI Pipeline (Jenkinsfile-CI)

### What it does

1. Checkout source from Git
2. `npm ci` — install dependencies
3. `npm test` — run Jest tests (JUnit results published)
4. `docker build` — build image tagged with short commit SHA
5. `docker push` — push to ECR (creates repo if missing)
6. Archives `image_tag.txt` for the CD pipeline to consume

### Jenkins Setup

**Credentials** (Manage Jenkins → Credentials):
| ID | Type | Description |
|----|------|-------------|
| `aws-credentials` | AWS Credentials | Access Key + Secret with ECR permissions |

**Environment Variables** (job config or Jenkinsfile env block):
| Variable | Example |
|----------|---------|
| `AWS_ACCOUNT_ID` | `123456789012` |
| `AWS_REGION` | `us-east-1` |
| `ECR_REPO_NAME` | `hello-world-api` |

**Required plugins**: Pipeline, AWS Credentials, JUnit

---

## Part 4 — Kubernetes Manifests

### Deploy Manually

```bash
# Configure kubectl
aws eks update-kubeconfig --region us-east-1 --name <cluster-name>

# Substitute your ECR image URI in deployment.yaml first:
# image: <account-id>.dkr.ecr.<region>.amazonaws.com/hello-world-api:<tag>

kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml

# Watch rollout
kubectl rollout status deployment/hello-world-api

# Get ALB DNS (takes ~60s to provision)
kubectl get ingress hello-world-api
```

### Ingress (ALB)

The Ingress uses `alb.ingress.kubernetes.io/scheme: internet-facing` to create a public-facing ALB. The ALB Ingress Controller (deployed via the `eks-assignment` Terraform) provisions the ALB automatically.

To enable HTTPS, uncomment the ACM cert annotation in `k8s/ingress.yaml` and add your certificate ARN.

---

## Part 5 — CD Pipeline (Jenkinsfile-CD)

### What it does

1. Checkout source
2. `aws eks update-kubeconfig` — authenticates kubectl
3. Patches `deployment.yaml` with the target ECR image + tag
4. `kubectl apply` — applies all three manifests
5. `kubectl rollout status` — waits for pods to become ready
6. Smoke test — polls `GET /health` on the ALB DNS until HTTP 200 (3 min timeout)
7. On failure: automatically runs `kubectl rollout undo` to roll back

### Jenkins Setup

Same AWS credential as CI. Additional env vars:

| Variable | Example |
|----------|---------|
| `EKS_CLUSTER_NAME` | `my-eks-cluster` |
| `K8S_NAMESPACE` | `default` |

**Parameter**: `IMAGE_TAG` — pass the short commit SHA from the CI pipeline's `image_tag.txt` artifact.

### Chaining CI → CD

In the CI pipeline's `post { success }` block, trigger the CD pipeline:

```groovy
build job: 'hello-world-api-CD',
      parameters: [string(name: 'IMAGE_TAG', value: "${IMAGE_TAG}")]
```

---

## Prerequisites

| Tool | Version |
|------|---------|
| Node.js | >= 18 |
| Docker | >= 24 |
| AWS CLI | >= 2 |
| kubectl | >= 1.28 |
| Jenkins | >= 2.400 |
| EKS Cluster | See `eks-assignment/` |

The EKS cluster and ALB Ingress Controller must be provisioned first — see the `eks-assignment/` Terraform module in this same branch.
