# IaC Demo — Terraform + Helm + ArgoCD + Kubernetes

A complete Infrastructure as Code demonstration. A Java Spring Boot application and PostgreSQL database deployed across 3 environments (dev, test, prod) on a local Kubernetes cluster using GitOps.

Everything runs on your laptop inside a **k3d cluster** (Kubernetes in Docker). The only external dependencies are GitHub (repos + CI) and ghcr.io (Docker images — free, part of GitHub).

---

## Table of Contents

1. [Architecture](#architecture)
2. [Why Each Tool](#why-each-tool)
3. [Project Structure](#project-structure)
4. [One-Time Setup](#one-time-setup)
5. [Running the Demo](#running-the-demo)
6. [The Full CI/CD Flow](#the-full-cicd-flow)
7. [Promoting Between Environments](#promoting-between-environments)
8. [Teardown](#teardown)
9. [Quick Reference](#quick-reference)
10. [Troubleshooting](#troubleshooting)

---

## Architecture

Two GitHub repositories + one local Kubernetes cluster:

```
[Java App Repo on GitHub]             [IaC Repo on GitHub]          [Local k3d Cluster]
  src/  pom.xml  Dockerfile               helm/  terraform/              ┌─────────────┐
         │                                argocd/  .github/              │  dev ns      │
         │ push to main                        │                          │  java-app    │
         ▼                                     │ ArgoCD watches           │  postgresql  │
  GitHub Actions CI                            │ each branch              ├─────────────┤
    1. run tests                               │                          │  test ns     │
    2. build Docker image           dev branch─┼──────────────────────>  │  java-app    │
    3. push to ghcr.io             test branch─┼──────────────────────>  │  postgresql  │
    4. update values-dev.yaml      prod branch─┼──────────────────────>  ├─────────────┤
       on dev branch (PR)                      │                          │  prod ns     │
                                               │                          │  java-app    │
                                               │                          │  postgresql  │
                                               │                          └─────────────┘
```

**Branching strategy (IaC repo):**

| Branch | ArgoCD watches it and deploys to | Auto-sync? |
|--------|----------------------------------|------------|
| `dev`  | `dev` namespace                  | Yes        |
| `test` | `test` namespace                 | Yes        |
| `prod` | `prod` namespace                 | No — manual Sync click required |

**Promotion flow:**
```
App CI updates values-dev.yaml on dev branch
  → ArgoCD deploys to dev (automatic)
  → "Promote dev→test" workflow updates values-test.yaml on test branch (PR)
  → ArgoCD deploys to test (automatic after merge)
  → "Promote test→prod" workflow updates values-prod.yaml on prod branch (PR)
  → ArgoCD shows OutOfSync → you click Sync → prod deploys
```

---

## Why Each Tool

### Kubernetes (k3d)
Kubernetes runs and manages your containers — restarts them if they crash, scales them, handles networking and storage. **k3d** runs a lightweight Kubernetes cluster inside Docker containers on your laptop. Uses ~512MB RAM vs minikube's 2GB+. In a real company you'd use AWS EKS, Azure AKS, or Google GKE.

### Terraform
Provisions infrastructure in the correct order. Before Kubernetes can run anything, you need: the cluster itself, namespaces, secrets, and infrastructure tools (ArgoCD, Traefik). Terraform handles all of this and tracks state — run it twice and it won't create duplicates. `terraform destroy` cleanly removes everything.

Terraform can't create the k3d cluster AND talk to it in one shot (the cluster must exist before Terraform can connect). `setup.sh` solves this by creating the cluster first, then running Terraform.

### Helm
Kubernetes package manager. Instead of 3 nearly-identical YAML files per environment, you have one template with variables. Change the health check path in one place — all 3 environments get the update. Each environment only defines what's different in its own `values-<env>.yaml`.

### ArgoCD
GitOps engine — watches Git branches and syncs Kubernetes to match. When a branch changes, ArgoCD deploys the change automatically. Benefits:
- **Drift detection**: if someone manually changes something in the cluster, ArgoCD reverts it
- **Rollback**: revert a Git commit, ArgoCD rolls back the deployment
- **Audit trail**: Git history = deployment history
- **Visual dashboard**: shows all environments, health, sync status
- **Prod safety gate**: dev and test auto-sync, prod requires a manual Sync click

### GitHub Actions
CI pipeline running in the cloud (free). Triggered on push to `main` in the app repo:
1. Runs Maven tests against a real PostgreSQL container — stops here if any fail
2. Builds Docker image, pushes to `ghcr.io` (GitHub's free container registry)
3. Updates `values-dev.yaml` in the IaC repo with the new image tag

### ghcr.io (GitHub Container Registry)
Free Docker image registry built into GitHub. No separate account needed — you authenticate with your existing `GITHUB_TOKEN`. Images live at `ghcr.io/YOUR_USERNAME/java-app:1.0.0-abc1234`.

---

## Project Structure

```
terraform-helm-chart-project/
│
├── app-repo-ci/                    # CI for the Java app repo (copy into your app repo)
│   ├── ci.yml                      # test → build image → push ghcr.io → update IaC dev branch
│   └── README.md
│
├── argocd/
│   ├── applications/
│   │   ├── dev.yaml                # ArgoCD app watching dev branch → dev namespace
│   │   ├── test.yaml               # ArgoCD app watching test branch → test namespace
│   │   └── prod.yaml               # ArgoCD app watching prod branch → prod namespace (manual sync)
│   └── projects/
│       └── java-app.yaml           # ArgoCD project (which repos/namespaces are allowed)
│
├── docker/
│   ├── demo-app/                   # Sample Spring Boot app (use this as your app repo)
│   │   ├── pom.xml
│   │   └── src/main/java/com/demo/
│   │       ├── Application.java
│   │       └── HealthController.java
│   ├── Dockerfile                  # Expects pre-built app.jar at root
│   └── Dockerfile.demo
│
├── helm/
│   ├── java-app/                   # Custom Helm chart for the Spring Boot app
│   │   ├── templates/
│   │   │   ├── deployment.yaml     # Runs pods, sets env vars, health checks
│   │   │   ├── service.yaml        # ClusterIP service on port 8080
│   │   │   ├── ingress.yaml        # HTTP routing (disabled — use port-forward locally)
│   │   │   └── hpa.yaml            # Autoscaler (prod only)
│   │   ├── values.yaml             # Defaults (startup probe timings, resource limits)
│   │   ├── values-dev.yaml         # Dev overrides (image tag updated by CI)
│   │   ├── values-test.yaml        # Test overrides (image tag updated by promote workflow)
│   │   └── values-prod.yaml        # Prod overrides (image tag updated by promote workflow)
│   │
│   └── postgresql/                 # Custom Helm chart for PostgreSQL
│       ├── templates/
│       │   ├── statefulset.yaml    # StatefulSet with persistent storage
│       │   └── service.yaml        # ClusterIP service on port 5432
│       ├── values.yaml
│       ├── values-dev.yaml
│       ├── values-test.yaml
│       └── values-prod.yaml
│
├── secrets/
│   └── .env.example                # Template — copy to .env and fill in real values
│
├── scripts/
│   ├── setup.sh                    # Full bootstrap: cluster + terraform + ArgoCD
│   └── teardown.sh                 # Full cleanup: terraform destroy + delete cluster
│
├── terraform/
│   ├── main.tf                     # Cluster, namespaces, secrets, Traefik, ArgoCD, Sealed Secrets
│   ├── variables.tf                # Input variables
│   ├── outputs.tf
│   ├── providers.tf
│   ├── versions.tf
│   └── terraform.tfvars.example    # Template — auto-generated from .env by setup.sh
│
├── .github/workflows/
│   ├── ci.yml                      # IaC repo validation: lint Helm, validate Terraform
│   ├── promote-to-test.yml         # Reads tag from dev, writes to test branch (PR)
│   └── promote-to-prod.yml         # Reads tag from test, writes to prod branch (PR)
│
├── .gitignore
├── Makefile                        # Optional shortcuts (make setup, make teardown, etc.)
└── README.md
```

---

## One-Time Setup

Do this once. After this, teardown and redo as many times as you want with just `setup.sh`.

### Step 1: Install prerequisites

```bash
brew install docker kubectl k3d helm terraform git
```

Start Docker Desktop. Allocate at least 4GB RAM: Docker Desktop → Settings → Resources → Memory.

### Step 2: Create GitHub repos

Create two repos on GitHub (public or private):
- `terraform-helm-chart-project` — this IaC repo
- `java-app` — your Java application repo

### Step 3: Create a Personal Access Token (PAT)

GitHub → Settings → Developer settings → **Tokens (classic)** → Generate new token (classic):
- Expiration: 90 days
- Scopes: `repo` + `write:packages`

Copy it — you won't see it again.

### Step 4: Configure local secrets

```bash
cp secrets/.env.example secrets/.env
```

Edit `secrets/.env`:
```
DB_PASSWORD_DEV=choose-any-password
DB_PASSWORD_TEST=choose-any-password
DB_PASSWORD_PROD=choose-any-password

GITHUB_USERNAME=your-github-username
GITHUB_REPO=terraform-helm-chart-project
GITHUB_TOKEN=ghp_your_token_from_step_3
```

### Step 5: Push the IaC repo to GitHub

```bash
git init
git add .
git commit -m "Initial IaC setup"
git remote add origin https://github.com/YOUR_USERNAME/terraform-helm-chart-project.git
git branch -M main && git push -u origin main

git checkout -b dev && git push -u origin dev
git checkout -b test && git push -u origin test
git checkout -b prod && git push -u origin prod
git checkout main
```

### Step 6: Set up the app repo

```bash
# Copy demo app to a new folder
cp -r docker/demo-app ~/Desktop/java-app
cd ~/Desktop/java-app
mkdir -p .github/workflows
cp /path/to/terraform-helm-chart-project/app-repo-ci/ci.yml .github/workflows/ci.yml
cp /path/to/terraform-helm-chart-project/docker/Dockerfile .

git init && git add . && git commit -m "Initial commit"
git remote add origin https://github.com/YOUR_USERNAME/java-app.git
git branch -M main && git push -u origin main
```

App repo on GitHub → Settings → Secrets and variables → Actions:
- **Secret**: `IAC_REPO_TOKEN` = your PAT from Step 3
- **Variable**: `IAC_REPO` = `YOUR_USERNAME/terraform-helm-chart-project`

Also: App repo → Settings → Actions → General → Workflow permissions → **"Allow GitHub Actions to create and approve pull requests"** ✓

### Step 7: Same setting on IaC repo

IaC repo → Settings → Actions → General → Workflow permissions:
- Select **"Read and write permissions"**
- Check **"Allow GitHub Actions to create and approve pull requests"**

---

## Running the Demo

### Start the cluster

```bash
bash scripts/setup.sh
```

Takes ~5 minutes. Creates the k3d cluster, runs Terraform (installs ArgoCD, Traefik, Sealed Secrets, namespaces, secrets), applies ArgoCD app manifests.

### Open ArgoCD

```bash
kubectl port-forward svc/argocd-server -n argocd 8888:443
```

Open **https://localhost:8888** (accept the cert warning).

Get the password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Login: `admin` / password above.

If the IaC repo is **private**, add credentials in ArgoCD:
Settings → Repositories → Connect Repo → HTTPS → your repo URL + username + PAT.

### Watch ArgoCD sync

ArgoCD polls GitHub every ~3 minutes. Once it connects to your repo, `java-app-dev`, `postgresql-dev`, `java-app-test`, `postgresql-test` will sync automatically. `java-app-prod` and `postgresql-prod` need a manual Sync click.

```bash
kubectl get pods -n dev
kubectl get pods -n test
kubectl get pods -n prod
```

### Verify apps are running

```bash
kubectl port-forward svc/java-app-dev -n dev 9091:8080 &
sleep 2 && curl http://localhost:9091/actuator/health
```

Expected response:
```json
{"status":"UP","components":{"db":{"status":"UP"},...}}
```

---

## The Full CI/CD Flow

Push a change to `main` in the java-app repo:

```bash
cd ~/Desktop/java-app
# make any change
git add . && git commit -m "feat: my change" && git push
```

**What happens automatically:**
1. GitHub Actions runs tests against PostgreSQL — stops if any fail
2. Builds Docker image, pushes to `ghcr.io/YOUR_USERNAME/java-app:1.0.0-abc1234`
3. Clones IaC repo, updates `values-dev.yaml` image tag, opens PR to `dev` branch, auto-merges it
4. ArgoCD detects change in `dev` branch → deploys new image to dev namespace
5. The push to `dev` branch (step 3) automatically triggers the `promote-to-test` workflow — it creates a PR to update `values-test.yaml` on the `test` branch, but **does not merge it** — you review and merge manually

Watch the CI: App repo → Actions tab.
Watch the deployment: ArgoCD UI or `kubectl get pods -n dev -w`.

### Automation levels at a glance

| Stage | What triggers it | Who merges | ArgoCD deploys |
|-------|-----------------|------------|----------------|
| → dev | App CI on push to `main` (automatic) | CI auto-merges | Automatically |
| → test | Push to `dev` branch (automatic) | You merge the PR | Automatically after merge |
| → prod | You run the workflow manually | You merge the PR | You click Sync in ArgoCD UI |

The key distinction: **promote-to-test fires automatically** (triggered by the push to dev), but it only opens a PR — it never auto-merges into test. That PR is your gate to decide "yes, this is ready for testing".

---

## Promoting Between Environments

### Dev → Test (automatic + manual merge)

Triggered automatically when CI updates the dev branch. Creates a PR on the `test` branch that updates `values-test.yaml` with the new image tag.

Or trigger manually: IaC repo → Actions → **"Promote dev → test"** → Run workflow (pick `main`) → Run.

Review and merge the PR. ArgoCD auto-deploys to the test namespace.

Verify:
```bash
kubectl port-forward svc/java-app-test -n test 9092:8080 &
sleep 2 && curl http://localhost:9092/actuator/health
```

### Test → Prod (manual only)

IaC repo → Actions → **"Promote test → prod"** → Run workflow:
- Pick `main` branch
- Enter a reason/ticket number
- Run

Review and merge the PR. **ArgoCD will NOT auto-deploy prod.** Go to ArgoCD UI → `java-app-prod` → **SYNC** → Synchronize. Do the same for `postgresql-prod`.

Verify:
```bash
kubectl port-forward svc/java-app-prod -n prod 9093:8080 &
sleep 2 && curl http://localhost:9093/actuator/health
```

---

## Teardown

```bash
bash scripts/teardown.sh
```

Destroys the cluster and all Kubernetes resources. GitHub repos and ghcr.io images are untouched.

To start fresh:
```bash
bash scripts/setup.sh
```

---

## Quick Reference

```bash
# Start everything
bash scripts/setup.sh

# ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8888:443
# → https://localhost:8888

# ArgoCD password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Check pods
kubectl get pods -n dev
kubectl get pods -n test
kubectl get pods -n prod

# Port-forward to apps
kubectl port-forward svc/java-app-dev  -n dev  9091:8080 &
kubectl port-forward svc/java-app-test -n test 9092:8080 &
kubectl port-forward svc/java-app-prod -n prod 9093:8080 &

# Health check
curl http://localhost:9091/actuator/health
curl http://localhost:9092/actuator/health
curl http://localhost:9093/actuator/health

# Tear down
bash scripts/teardown.sh
```

---

## Troubleshooting

**ArgoCD apps stuck on Unknown/Missing**
- Branches must exist on GitHub (`dev`, `test`, `prod`)
- If repo is private: add credentials in ArgoCD → Settings → Repositories

**Pods not starting (ImagePullBackOff)**
- Terraform created `ghcr-pull-secret` in each namespace. Check it exists:
  `kubectl get secret ghcr-pull-secret -n dev`
- If missing: `cd terraform && terraform apply`

**App crashes on startup (CrashLoopBackOff)**
- Check logs: `kubectl logs -n dev deployment/java-app-dev`
- Usually a DB connection issue — check `postgresql-dev` pod is running first

**kubectl: no cluster / context not found**
- Docker was restarted and k3d cluster stopped: `bash scripts/setup.sh`

**CI fails: "cannot create pull request"**
- IaC repo → Settings → Actions → General → enable "Allow GitHub Actions to create and approve pull requests"

**Port 8080 already in use for ArgoCD**
- Use a different port: `kubectl port-forward svc/argocd-server -n argocd 8888:443`
