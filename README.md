# IaC Demo - Terraform + Helm + ArgoCD + Kubernetes

A complete, locally-runnable Infrastructure as Code demonstration. A Java Spring Boot application and PostgreSQL database are deployed across 3 environments (dev, test, prod) on a local Kubernetes cluster using GitOps.

Everything runs on your laptop inside a **k3d cluster** (lightweight Kubernetes in Docker). The only cloud dependency is GitHub for hosting the Git repository.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Why Each Tool? (Explained in Detail)](#why-each-tool-explained-in-detail)
3. [What Are the Helm Charts?](#what-are-the-helm-charts)
4. [Secrets Management](#secrets-management)
5. [Branching Strategy & GitOps Flow](#branching-strategy--gitops-flow)
6. [Prerequisites](#prerequisites)
7. [Step-by-Step: How to Run Everything](#step-by-step-how-to-run-everything)
8. [Step-by-Step: How to Show the Demo](#step-by-step-how-to-show-the-demo)
9. [Project Structure](#project-structure)
10. [Teardown](#teardown)
11. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

This is a **two-repository model**, just like in a real company:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│   APP REPO (Java application)          IAC REPO (this repository)       │
│   ┌─────────────────────────┐          ┌──────────────────────────┐     │
│   │                         │          │                          │     │
│   │  push to main           │          │  dev branch              │     │
│   │    │                    │          │    │  (auto-updated by   │     │
│   │    ▼                    │  updates │    │   app repo CI)      │     │
│   │  GitHub Actions CI      │────────> │    │                     │     │
│   │    │                    │ (changes │    ▼                     │     │
│   │    ├─ build JAR         │  image   │  test branch             │     │
│   │    ├─ build Docker image│  tag in  │    │  (you merge         │     │
│   │    ├─ push to registry  │  values- │    │   dev -> test)      │     │
│   │    └─ update IaC repo   │  dev.yml)│    │                     │     │
│   │       dev branch        │          │    ▼                     │     │
│   │                         │          │  prod branch             │     │
│   └─────────────────────────┘          │    (you merge            │     │
│                                         │     test -> prod)       │     │
│                                         └──────────┬─────────────┘     │
│                                                     │                   │
│   ┌─────────────────────────────────────────────────┼──────────────┐    │
│   │  k3d Cluster (Kubernetes on your laptop)        │              │    │
│   │                                                  │              │    │
│   │  ┌──────────────────┐                           │              │    │
│   │  │  ArgoCD           │<──────────────────────────┘              │    │
│   │  │  watches branches │                                          │    │
│   │  └───────┬───────────┘                                          │    │
│   │          │                                                      │    │
│   │   ┌──────┴──────────────────────────────────────────┐           │    │
│   │   │  dev ns         test ns         prod ns         │           │    │
│   │   │  ┌─────────┐   ┌─────────┐   ┌─────────┐      │           │    │
│   │   │  │Java App │   │Java App │   │Java App │      │           │    │
│   │   │  │PostgreSQL│   │PostgreSQL│   │PostgreSQL│      │           │    │
│   │   │  └─────────┘   └─────────┘   └─────────┘      │           │    │
│   │   └─────────────────────────────────────────────────┘           │    │
│   └─────────────────────────────────────────────────────────────────┘    │
��                                                                         │
│                          YOUR LAPTOP                                    │
└─────────────────────────────────────────────────────────────────────────┘
```

**The full deployment flow:**
1. You push code to `main` in the **app repo**
2. App repo CI builds the JAR, builds a Docker image, pushes it to the local registry
3. App repo CI **automatically updates the image tag** in the **IaC repo's `dev` branch** (creates a PR and auto-merges it)
4. ArgoCD detects the change in the `dev` branch and **auto-deploys to the dev namespace**
5. To promote to test: you merge `dev` -> `test` branch in the IaC repo
6. To promote to prod: you merge `test` -> `prod` branch (ArgoCD waits for manual sync)

**What's running inside the cluster:**
- **ArgoCD** - watches your GitHub repo, auto-deploys when you push
- **Traefik** - ingress controller (routes external traffic to the right service)
- **Sealed Secrets** controller - decrypts encrypted secrets
- **3 namespaces** (dev, test, prod), each containing:
  - 1 Java Spring Boot application (Deployment)
  - 1 PostgreSQL database (StatefulSet with persistent storage)
  - 1 Kubernetes Secret (database password)

---

## Why Each Tool? (Explained in Detail)

### Why Kubernetes (k3d)?

Kubernetes (K8s) is the container orchestration platform. It handles:
- Running your containers (pods)
- Restarting them if they crash
- Scaling them up/down
- Load balancing traffic between replicas
- Managing storage, secrets, and networking

**k3d** specifically is a tool that runs a **k3s cluster** (lightweight Kubernetes) **inside Docker containers**. We use it because:
- A full Kubernetes cluster (like EKS on AWS or GKE on Google Cloud) runs in the cloud and costs money
- Minikube (another local K8s tool) uses 2GB+ of RAM
- k3d uses ~512MB RAM, which is critical since we're running 3 environments + ArgoCD + Traefik on a laptop
- k3d includes a built-in local Docker registry (so we don't need Docker Hub)

**In a real company:** you'd use AWS EKS, Azure AKS, or Google GKE instead. k3d is our local replacement.

### Why Terraform?

Terraform is the **infrastructure provisioner**. It creates and manages the infrastructure that our application runs on.

**What it does in this project** (see `terraform/main.tf`):
1. Creates the k3d cluster and local Docker registry
2. Creates 3 Kubernetes namespaces (dev, test, prod) + argocd namespace
3. Creates the database password secrets in each namespace
4. Installs Traefik (ingress controller) via its Helm chart
5. Installs ArgoCD via its Helm chart
6. Installs Sealed Secrets controller via its Helm chart
7. Registers ArgoCD applications (tells ArgoCD what to deploy where)

**Why not just run these commands manually or in a shell script?**

| Problem | Shell Script | Terraform |
|---------|-------------|-----------|
| Run it twice, does it create duplicates? | Yes, you need to add `if ! exists` checks everywhere | No. Terraform tracks state - it knows what already exists |
| What order to run things? | You figure it out yourself | Terraform builds a dependency graph automatically |
| Something fails halfway through? | You manually figure out what was created and what wasn't | Terraform knows exactly what state things are in |
| Want to see what will change before applying? | No preview | `terraform plan` shows the exact diff |
| Want to destroy everything cleanly? | Write another script in reverse order | `terraform destroy` removes everything in the correct order |

**In a real company:** Terraform would create cloud resources - VPCs, subnets, EKS clusters, RDS databases, IAM roles. Here it creates the local equivalents.

### Why Helm?

Helm is the **Kubernetes package manager**. It turns Kubernetes YAML files into **reusable, configurable templates**.

**The problem Helm solves:**

Without Helm, to deploy our Java app to 3 environments, you'd need:
```
k8s/dev/deployment.yaml     (replicas: 1, memory: 256Mi, env: dev)
k8s/dev/service.yaml
k8s/test/deployment.yaml    (replicas: 1, memory: 512Mi, env: test)
k8s/test/service.yaml
k8s/prod/deployment.yaml    (replicas: 2, memory: 512Mi, env: prod)
k8s/prod/service.yaml
```

That's 6 nearly identical files. If you change the health check path, you edit 3 files. If you add a new environment variable, you edit 3 files. Copy-paste errors guaranteed.

**With Helm:**
```
helm/java-app/
  templates/deployment.yaml   <-- ONE template with {{ .Values.replicas }} placeholders
  templates/service.yaml      <-- ONE template
  values-dev.yaml             <-- dev:  replicas: 1,  memory: 256Mi
  values-test.yaml            <-- test: replicas: 1,  memory: 512Mi
  values-prod.yaml            <-- prod: replicas: 2,  memory: 512Mi, autoscaling: on
```

Change a template once, all 3 environments get the update. Change a value in `values-prod.yaml`, only prod changes.

### Why ArgoCD?

ArgoCD is the **GitOps deployment engine**. It watches your Git repository and automatically deploys changes to Kubernetes.

**Without ArgoCD**, your deployment workflow is:
1. Developer pushes code to Git
2. CI builds a Docker image
3. Someone manually runs `helm upgrade java-app-dev helm/java-app/ -f values-dev.yaml -n dev`
4. Hope they used the right values file and right namespace
5. If something breaks, manually roll back

**With ArgoCD**, your deployment workflow is:
1. Developer pushes code to Git
2. CI builds a Docker image
3. **Done.** ArgoCD detects the change and deploys automatically.

ArgoCD also gives you:
- **Drift detection** - if someone manually changes something in the cluster (kubectl edit, etc.), ArgoCD reverts it back to match what's in Git
- **Rollback** - revert a Git commit and ArgoCD automatically rolls back the deployment
- **Audit trail** - Git history IS your deployment history. You can always see who changed what and when
- **Visual dashboard** - a web UI showing all environments, their sync status, health, and deployment history
- **Manual approval for prod** - dev and test auto-sync, but prod requires you to click "Sync" in the UI (safety gate)

### Why Sealed Secrets?

Kubernetes Secrets are just **base64-encoded, NOT encrypted**. Anyone who can read the YAML file can decode the password:

```bash
echo "bXlwYXNzd29yZA==" | base64 -d
# Output: mypassword
```

So you can't commit K8s Secret YAML files to Git. But in a GitOps workflow, ArgoCD deploys everything from Git. How do you manage secrets?

**Sealed Secrets** solves this:
1. You encrypt a secret using `kubeseal` and the cluster's public key
2. The result is a `SealedSecret` YAML - encrypted, safe to commit to Git
3. The Sealed Secrets controller in the cluster decrypts it into a regular K8s Secret
4. Only the controller has the private key - nobody else can decrypt it

### Why a local Docker registry?

When k3d creates pods, Kubernetes needs to pull the Docker image from somewhere. Options:
- **Docker Hub** - requires internet, rate limits, public unless you pay
- **GitHub Container Registry** - requires internet and auth tokens
- **Local registry at ghcr.io/YOUR_USERNAME** - instant pulls, no internet needed, no auth

We use k3d's built-in local registry. When you build your Java app image, you push it to `ghcr.io/YOUR_USERNAME/java-app:latest`, and the k3d cluster pulls it instantly from there.

### Why GitHub Actions + act?

GitHub Actions is the **CI pipeline** - it runs when you push to GitHub:
- Builds the Java app with Maven
- Creates a Docker image
- Lints Helm charts (checks for syntax errors)
- Validates Terraform configuration

**act** is a tool that runs GitHub Actions workflows **locally in Docker**, so you can test your CI pipeline without pushing to GitHub.

---

## What Are the Helm Charts?

Both Helm charts in this project are **custom charts we wrote ourselves**. They are NOT pulled from a public Helm chart repository (like Bitnami or ArtifactHub).

### `helm/java-app/` - Our custom chart for the Spring Boot application

We wrote this chart specifically for our Java app. It contains 4 templates:

| Template file | What K8s resource it creates | What it does |
|---------------|------------------------------|-------------|
| `deployment.yaml` | Deployment | Runs the Java app containers. Sets environment variables (DB_URL, DB_PASSWORD from a secret, APP_ENVIRONMENT). Configures liveness and readiness health checks against `/actuator/health`. |
| `service.yaml` | Service (ClusterIP) | Creates an internal DNS name so other pods (and the ingress) can reach the app on port 8080. |
| `ingress.yaml` | Ingress | Routes external HTTP traffic from a hostname (like `dev.java-app.local`) to the service. Only created if `ingress.enabled: true` in the values file. |
| `hpa.yaml` | HorizontalPodAutoscaler | Auto-scales pods when CPU usage exceeds a threshold. Only created if `autoscaling.enabled: true` (only in prod). |

**Per-environment values:**
| Setting | dev | test | prod |
|---------|-----|------|------|
| Replicas | 1 | 1 | 2 |
| Memory limit | 384Mi | 512Mi | 512Mi |
| Autoscaling | off | off | on (2-4 pods) |
| Ingress host | dev.java-app.local | test.java-app.local | java-app.local |

### `helm/postgresql/` - Our custom chart for PostgreSQL

We wrote a **minimal** PostgreSQL chart. We intentionally did NOT use the Bitnami PostgreSQL chart, which has 500+ lines of templates for high availability, replication, metrics exporters, backup CronJobs, etc. That's overkill for a demo.

Our chart has 2 templates:

| Template file | What K8s resource it creates | What it does |
|---------------|------------------------------|-------------|
| `statefulset.yaml` | StatefulSet | Runs PostgreSQL. Uses a PersistentVolumeClaim so data survives pod restarts. Gets the database password from a K8s Secret. |
| `service.yaml` | Service (ClusterIP) | Exposes PostgreSQL on port 5432 so the Java app can connect via DNS name (e.g., `postgresql-dev:5432`). |

**Why StatefulSet instead of Deployment?** Databases need two things that Deployment doesn't guarantee:
1. **Stable storage** - if the pod restarts, it must get the same disk back (not a fresh empty one)
2. **Stable network identity** - the pod must always be reachable at the same DNS name

StatefulSet guarantees both. Deployment is for stateless applications.

**Per-environment values:**
| Setting | dev | test | prod |
|---------|-----|------|------|
| Storage | 512Mi | 512Mi | 2Gi |
| Memory limit | 192Mi | 256Mi | 512Mi |
| Database name | appdb_dev | appdb_test | appdb_prod |

---

## Secrets Management

**No passwords are hardcoded in any committed file.** Here's how secrets flow through the system:

```
secrets/.env              <-- You create this (gitignored, never committed)
    │
    └──> scripts/setup.sh  (reads .env and generates terraform.tfvars)
            │
            └──> terraform/terraform.tfvars   (also gitignored)
                    │
                    └──> Terraform creates K8s Secrets in each namespace
                            │
                            └──> Pods read passwords from K8s Secrets
```

**For production (Sealed Secrets approach):**
```
You (run kubeseal CLI locally)
    │
    ├──> Encrypt secret with cluster's public key
    │
    └──> SealedSecret YAML (encrypted, safe to commit to Git!)
            │
            └──> ArgoCD syncs it to the cluster
                    │
                    └──> Sealed Secrets controller decrypts it in-cluster
                            │
                            └──> Regular K8s Secret (only exists in cluster memory)
```

The `secrets/.env.example` file is the only secrets-related file committed to Git. It contains placeholder values that you replace with real passwords.

---

## Branching Strategy & GitOps Flow

There are **two repositories** with different branching strategies:

### App Repository (Java application)

```
feature/xyz ──> main
                 │
                 ▼
              CI pipeline runs
                 │
                 ├─ builds JAR
                 ├─ builds Docker image (tagged with git SHA)
                 ├─ pushes image to local registry
                 └─ updates IaC repo dev branch with new image tag
```

The app repo has a simple trunk-based flow. Every merge to `main` triggers a build and auto-deployment to dev.

### IaC Repository (this repo)

```
dev branch ───(merge PR)──> test branch ───(merge PR)──> prod branch
     │                           │                            │
     ▼                           ▼                            ▼
  dev namespace              test namespace              prod namespace
  (auto-sync)                (auto-sync)                (MANUAL sync)
```

Each branch maps to an environment. ArgoCD watches each branch:

| Action | What happens |
|--------|-------------|
| App repo CI updates `dev` branch | ArgoCD auto-deploys to **dev** namespace |
| You merge `dev` -> `test` (via PR) | ArgoCD auto-deploys to **test** namespace |
| You merge `test` -> `prod` (via PR) | ArgoCD detects change but **waits** for manual sync |
| You click "Sync" in ArgoCD UI | **prod** deploys |

**Why is prod manual?** Safety. In a real company, you want a human to confirm that tests passed and the release is approved before deploying to production. ArgoCD shows you the exact diff of what will change, and you click "Sync" when ready.

**Why separate branches instead of folders?** Because ArgoCD's `targetRevision` (which branch to watch) is the cleanest way to isolate environments. Each branch contains the same Helm charts but with different image tags in the values files. When you merge dev -> test, the test environment gets exactly the same image version that was running in dev.

---

## Prerequisites

Install everything with Homebrew (macOS):

```bash
brew install docker
brew install kubectl
brew install k3d
brew install helm
brew install terraform
brew install maven
```

Optional:
```bash
brew install act        # Run GitHub Actions locally
brew install kubeseal   # Encrypt secrets for Sealed Secrets
```

**Docker Desktop** must be running with at least **4GB RAM** allocated.
(Docker Desktop > Settings > Resources > Memory > 4GB)

Verify everything is installed:
```bash
docker --version
kubectl version --client
k3d version
helm version
terraform version
mvn --version
```

---

## Step-by-Step: How to Run Everything

### Step 1: Configure your secrets

```bash
# Copy the template
cp secrets/.env.example secrets/.env
```

Open `secrets/.env` in any editor and set your values:
```
DB_PASSWORD_DEV=my-dev-password-123
DB_PASSWORD_TEST=my-test-password-456
DB_PASSWORD_PROD=my-prod-password-789
GITHUB_USERNAME=your-actual-github-username
GITHUB_REPO=terraform-helm-chart-project
```

### Step 2: Create the local Docker registry

k3d can run a Docker registry as a container on your machine. This is where we push our built images.

```bash
k3d registry create iac-registry --port 5111
```

Verify it's running:
```bash
docker ps | grep registry
```

### Step 3: Create the k3d Kubernetes cluster

```bash
k3d cluster create iac-demo \
  --registry-use k3d-iac-registry:5111 \
  --servers 1 \
  --agents 1 \
  --k3s-arg "--disable=traefik@server:0" \
  --port "8080:80@loadbalancer" \
  --port "8443:443@loadbalancer" \
  --wait
```

What this does:
- `--registry-use` - connects the cluster to our local registry so pods can pull images from it
- `--servers 1 --agents 1` - minimal cluster (1 control plane + 1 worker node) to save RAM
- `--disable=traefik@server:0` - disables the default Traefik so we install our own via Terraform
- `--port "8080:80@loadbalancer"` - maps port 8080 on your laptop to port 80 in the cluster

Verify the cluster is ready:
```bash
kubectl cluster-info
kubectl get nodes
```

You should see 2 nodes (1 server + 1 agent), both in `Ready` state.

### Step 4: Build and push the Java app Docker image

```bash
# Build the Java app with Maven
cd docker/demo-app
mvn package -DskipTests -q
cp target/*.jar ../app.jar
cd ../..

# Build the Docker image and push to local registry
docker build -t ghcr.io/YOUR_USERNAME/java-app:latest -f docker/Dockerfile docker/
docker push ghcr.io/YOUR_USERNAME/java-app:latest
```

Verify the image is in the registry:
```bash
curl -s http://ghcr.io/YOUR_USERNAME/v2/_catalog
# Should show: {"repositories":["java-app"]}
```

### Step 5: Generate terraform.tfvars from your secrets

```bash
# Source your secrets
source secrets/.env

# Generate the Terraform variables file
cat > terraform/terraform.tfvars <<EOF
github_repo_url = "https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"

db_passwords = {
  dev  = "${DB_PASSWORD_DEV}"
  test = "${DB_PASSWORD_TEST}"
  prod = "${DB_PASSWORD_PROD}"
}
EOF
```

### Step 6: Run Terraform

```bash
cd terraform

# Download providers (Kubernetes, Helm, etc.)
terraform init

# Preview what Terraform will create
terraform plan

# Create everything
terraform apply
```

Terraform will ask you to confirm with `yes`. Type `yes` and press Enter.

What Terraform creates:
- Namespaces: `dev`, `test`, `prod`, `argocd`
- K8s Secrets with database passwords in each namespace
- Traefik ingress controller (in kube-system namespace)
- Sealed Secrets controller (in kube-system namespace)
- ArgoCD (in argocd namespace)
- ArgoCD Project and Application resources

This takes about 2-5 minutes (mostly waiting for ArgoCD to become healthy).

```bash
cd ..
```

Verify everything:
```bash
# Check namespaces
kubectl get namespaces

# Check ArgoCD is running
kubectl get pods -n argocd

# Check all namespaces have their secrets
kubectl get secrets -n dev
kubectl get secrets -n test
kubectl get secrets -n prod
```

### Step 7: Update ArgoCD application manifests with your repo URL

```bash
# Replace the placeholder with your actual GitHub repo URL
source secrets/.env
REPO_URL="https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"

sed -i '' "s|https://github.com/YOUR_USERNAME/terraform-helm-chart-project.git|${REPO_URL}|g" argocd/applications/dev.yaml
sed -i '' "s|https://github.com/YOUR_USERNAME/terraform-helm-chart-project.git|${REPO_URL}|g" argocd/applications/test.yaml
sed -i '' "s|https://github.com/YOUR_USERNAME/terraform-helm-chart-project.git|${REPO_URL}|g" argocd/applications/prod.yaml
```

Re-apply the ArgoCD applications:
```bash
kubectl apply -f argocd/applications/dev.yaml
kubectl apply -f argocd/applications/test.yaml
kubectl apply -f argocd/applications/prod.yaml
```

### Step 8: Access the ArgoCD dashboard

```bash
# Get the auto-generated admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
# Save this password somewhere
```

```bash
# Start port-forwarding (keep this terminal open)
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open your browser: **https://localhost:8080**
- Accept the self-signed certificate warning
- Username: `admin`
- Password: (the password from the command above)

### Step 9: Push to GitHub and create environment branches

```bash
# Initialize the repo
git init
git add .
git commit -m "Initial IaC setup"
git remote add origin https://github.com/YOUR_USERNAME/terraform-helm-chart-project.git
git branch -M main
git push -u origin main

# Create the 3 environment branches (ArgoCD watches these)
git checkout -b dev
git push -u origin dev

git checkout -b test
git push -u origin test

git checkout -b prod
git push -u origin prod

# Go back to main
git checkout main
```

Go to the ArgoCD dashboard. Within 1-3 minutes, you'll see the applications start syncing:
- `java-app-dev` and `postgresql-dev` sync from the `dev` branch
- `java-app-test` and `postgresql-test` sync from the `test` branch
- `java-app-prod` and `postgresql-prod` show "OutOfSync" (waiting for manual sync)

### Step 10: Verify the applications are running

```bash
# See all pods across all environments
kubectl get pods -n dev
kubectl get pods -n test
kubectl get pods -n prod

# Check the dev Java app
kubectl port-forward svc/java-app-dev -n dev 9090:8080
# In another terminal:
curl http://localhost:9090/
# Returns: {"service":"java-app","environment":"dev","version":"1.0.0-dev","status":"running"}
```

---

## Step-by-Step: How to Show the Demo

### Part 1: "Here's the application" (2 min)

Show the Java app source code:
```bash
cat docker/demo-app/src/main/java/com/demo/HealthController.java
```

Explain: "This is a simple Spring Boot REST API. It connects to PostgreSQL and returns its environment info."

Hit the running app:
```bash
curl http://localhost:9090/
curl http://localhost:9090/api/info
```

### Part 2: "Here's the infrastructure as code" (5 min)

Show what Terraform manages:
```bash
cat terraform/main.tf
```

Explain each section: "Terraform creates the cluster, namespaces, installs ArgoCD, creates the database secrets."

Show the Helm chart structure:
```bash
cat helm/java-app/templates/deployment.yaml
cat helm/java-app/values-dev.yaml
cat helm/java-app/values-prod.yaml
```

Explain: "One template, different values per environment. Dev gets 1 replica with 384Mi RAM. Prod gets 2 replicas with autoscaling."

Show how ArgoCD connects branches to environments:
```bash
cat argocd/applications/dev.yaml   # targetRevision: develop
cat argocd/applications/prod.yaml  # targetRevision: main
```

### Part 3: "Watch GitOps in action" (5 min)

Open the ArgoCD dashboard in the browser (https://localhost:8080).

Show all 6 applications: java-app-dev, postgresql-dev, java-app-test, postgresql-test, java-app-prod, postgresql-prod.

Simulate what the app repo CI would do - update the image tag on the dev branch:
```bash
git checkout dev

# Change the image tag in dev values (simulating what app repo CI does automatically)
# Edit helm/java-app/values-dev.yaml - change tag from "latest" to "abc1234"
# and change APP_VERSION from "1.0.0-dev" to "2.0.0-abc1234"

git add helm/java-app/values-dev.yaml
git commit -m "deploy(dev): update java-app to abc1234"
git push
```

Switch to the ArgoCD UI. Click "Refresh" on the java-app-dev application. Watch it detect the change and re-sync. The pod will restart with the new version.

Verify:
```bash
curl http://localhost:9090/api/info
# Returns: {"environment":"dev","version":"2.0.0-abc1234"}
```

Explain: "In the real flow, you never do this manually. The app repo CI automatically creates a PR to the dev branch and merges it."

### Part 4: "Promote through environments" (3 min)

```bash
# Promote to test: merge dev -> test
git checkout test
git merge dev
git push
```

ArgoCD auto-deploys to the test namespace. Show it syncing in the UI.

```bash
# Promote to prod: merge test -> prod
git checkout prod
git merge test
git push
```

In ArgoCD, the prod apps show "OutOfSync" but do NOT auto-deploy. Explain: "Production requires a manual sync for safety." Click "Sync" to deploy.

In a real workflow, these merges would be done via Pull Requests with code review and approval.

### Part 5: "How secrets are handled" (2 min)

```bash
# Show that secrets/.env is gitignored
cat .gitignore | grep secrets

# Show the template that IS committed
cat secrets/.env.example

# Show that K8s secrets exist but values are hidden
kubectl get secret java-app-db-secret -n dev -o yaml
# The data field shows base64-encoded values, but they came from your .env file
# They are NOT hardcoded anywhere in the repo
```

---

## Project Structure

```
terraform-helm-chart-project/
│
├── app-repo-ci/                   # CI workflow for the JAVA APP repo (not this repo)
│   ├── ci.yml                     # GitHub Actions: build -> push image -> update IaC repo dev branch
│   └── README.md                  # How to set it up in your app repo
│
├── argocd/                        # ArgoCD configuration
│   ├── applications/
│   │   ├── dev.yaml               # Watches 'develop' branch -> deploys to dev namespace
│   │   ├── test.yaml              # Watches 'release/*' branches -> deploys to test namespace
│   │   └── prod.yaml              # Watches 'main' branch -> deploys to prod namespace (manual sync)
│   └── projects/
│       └── java-app.yaml          # Defines which repos/namespaces ArgoCD is allowed to use
│
├── docker/
│   ├── demo-app/                  # Sample Spring Boot application source code
│   │   ├── pom.xml                # Maven build file (dependencies: Spring Web, JPA, PostgreSQL)
│   │   └── src/main/java/com/demo/
│   │       ├── Application.java   # Spring Boot entry point
│   │       └── HealthController.java  # REST endpoints: / and /api/info
│   ├── Dockerfile                 # Production image (expects pre-built JAR)
│   └── Dockerfile.demo            # Development image (builds JAR from source inside Docker)
│
├── helm/
│   ├── java-app/                  # CUSTOM Helm chart - we wrote this for our Spring Boot app
│   │   ├── Chart.yaml             # Chart metadata (name, version)
│   │   ├── templates/
│   │   │   ├── _helpers.tpl       # Template helper functions (naming, labels)
│   │   │   ├── deployment.yaml    # Runs the Java app pods with env vars and health checks
│   │   │   ├── service.yaml       # Internal ClusterIP service on port 8080
│   │   │   ├── ingress.yaml       # External HTTP routing (optional, per-env)
│   │   │   └── hpa.yaml           # Pod autoscaler (optional, prod only)
│   │   ├── values.yaml            # Default values (base)
│   │   ├── values-dev.yaml        # Dev: 1 replica, small memory, relaxed limits
│   │   ├── values-test.yaml       # Test: 1 replica, medium memory
│   │   └── values-prod.yaml       # Prod: 2 replicas, autoscaling, strict limits
│   │
│   └── postgresql/                # CUSTOM Helm chart - we wrote this for PostgreSQL
│       ├── Chart.yaml
│       ├── templates/
│       │   ├── _helpers.tpl
│       │   ├── statefulset.yaml   # StatefulSet with persistent storage
│       │   └── service.yaml       # ClusterIP service on port 5432
│       ├── values.yaml
│       ├── values-dev.yaml        # Dev: 512Mi storage, minimal resources
│       ├── values-test.yaml       # Test: 512Mi storage, moderate resources
│       └── values-prod.yaml       # Prod: 2Gi storage, higher limits
│
├── k8s/
│   ├── namespaces/                # Namespace YAML definitions (reference, created by Terraform)
│   └── secrets/
│       └── README.md              # Explains Terraform secrets + Sealed Secrets workflow
│
├── secrets/
│   └── .env.example               # Template with placeholder passwords (committed to Git)
│                                  # You copy this to .env (gitignored) and fill in real values
│
├── scripts/
│   ├── setup.sh                   # Automated bootstrap (runs all the steps above)
│   └── teardown.sh                # Automated cleanup (destroys cluster + registry)
│
├── terraform/
│   ├── main.tf                    # All infrastructure: cluster, namespaces, ArgoCD, Traefik, secrets
│   ├── variables.tf               # Input variables (no defaults for secrets)
│   ├── outputs.tf                 # Outputs: registry URL, cluster name, ArgoCD URL
│   ├── providers.tf               # Kubernetes + Helm provider configuration
│   ├── versions.tf                # Required Terraform + provider versions
│   └── terraform.tfvars.example   # Template for Terraform variables (committed)
│                                  # You copy this to terraform.tfvars (gitignored)
│
├── .github/workflows/
│   └── ci.yml                     # GitHub Actions: build JAR, Docker image, lint Helm, validate TF
│
├── .actrc                         # Config for running GitHub Actions locally with 'act'
├── .gitignore                     # Ignores: .env, terraform.tfvars, .tfstate, .terraform/, .jar
├── Makefile                       # Shortcut commands (optional, see note below)
└── README.md                      # This file
```

> **Note on the Makefile:** The `Makefile` contains shortcut commands like `make setup` which just runs `bash scripts/setup.sh`. You don't need to use it - every command in this README is the actual raw command. The Makefile just saves typing for repeated operations.

---

## Teardown

To destroy everything and free up all resources:

```bash
# Step 1: Terraform destroy (removes ArgoCD, namespaces, secrets)
cd terraform
terraform destroy
# Type 'yes' to confirm
cd ..

# Step 2: Delete the k3d cluster
k3d cluster delete iac-demo

# Step 3: Delete the local registry
k3d registry delete k3d-iac-registry

# Verify nothing is left
k3d cluster list
k3d registry list
docker ps  # Should show no k3d-related containers
```

Or use the teardown script which does all of the above:
```bash
bash scripts/teardown.sh
```

---

## Troubleshooting

**"error: context 'k3d-iac-demo' does not exist"**
```bash
k3d cluster list                # Is the cluster there?
k3d cluster start iac-demo      # Start it if stopped
kubectl config get-contexts     # List available contexts
```

**ArgoCD apps stestk in "Unknown" or "Missing"**
- The repo URL in `argocd/applications/*.yaml` must match your actual GitHub repo
- The repo must be public, OR you must configure ArgoCD with a GitHub token for private repos
- ArgoCD needs internet access to pull from GitHub

**Pods in CrashLoopBackOff**
```bash
kubectl logs -n dev deployment/java-app-dev          # Check Java app logs
kubectl describe pod -n dev -l app.kubernetes.io/name=java-app  # Check events
kubectl logs -n dev statefulset/postgresql-dev        # Check PostgreSQL logs
```

**Image pull errors (ErrImagePull)**
```bash
# Verify image exists in local registry
curl -s http://ghcr.io/YOUR_USERNAME/v2/_catalog

# If empty, rebuild and push
docker build -t ghcr.io/YOUR_USERNAME/java-app:latest -f docker/Dockerfile docker/
docker push ghcr.io/YOUR_USERNAME/java-app:latest
```

**Terraform errors about provider versions**
```bash
cd terraform
rm -rf .terraform .terraform.lock.hcl
terraform init
```

**Out of memory on laptop**
- Ensure Docker Desktop has 4GB RAM allocated
- k3d + ArgoCD + 3 envs uses approximately 2-3GB total
- If still tight, temporarily scale down: edit `values-test.yaml` and `values-prod.yaml` to reduce resource requests
