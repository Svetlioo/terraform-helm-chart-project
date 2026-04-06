# Demo Guide — Start to End

## What you are building

Two GitHub repositories + one local Kubernetes cluster:

```
[App repo on GitHub]          [IaC repo on GitHub]         [Local k3d cluster]
  Java source code    →CI→    Helm values + ArgoCD   →CD→   dev / test / prod
  push to main                (this repo)                    namespaces
       |                            |
       | builds Docker image        | ArgoCD watches branches
       ↓                            ↓
  ghcr.io (GitHub's free      ArgoCD auto-syncs dev+test,
  container registry)         manual sync for prod
```

**Everything runs locally except:**
- GitHub (hosts both repos + runs CI)
- ghcr.io (stores Docker images — it is part of GitHub, free)

---

## Why does setup.sh exist if there is Terraform?

Terraform manages Kubernetes resources (namespaces, secrets, Helm releases).
But Terraform cannot create the k3d cluster itself — the Kubernetes cluster must exist before Terraform can talk to it. This is the chicken-and-egg problem.

`setup.sh` solves it by running things in the right order:
1. Reads your secrets from `.env`
2. Creates the k3d cluster (via k3d CLI)
3. Waits for the cluster to be ready
4. Then runs Terraform (which installs ArgoCD, Traefik, creates namespaces, secrets, etc.)
5. Applies ArgoCD application manifests

You could do all of this by hand — `setup.sh` just automates the sequence.

---

## Prerequisites

Install everything:
```bash
brew install docker kubectl k3d helm terraform git
```

Start Docker Desktop and make sure it is running:
```bash
docker info   # should not error
```

---

## Part 1 — One-time GitHub setup (do this once)

### Step 1: Create the IaC repo on GitHub

Go to github.com → New repository:
- Name: `terraform-helm-chart-project`
- Visibility: Public or Private
- Do NOT initialize with README (you already have files)

### Step 2: Create the app repo on GitHub

Go to github.com → New repository:
- Name: `java-app` (or whatever your Java project is called)
- Visibility: Public or Private

### Step 3: Create a GitHub Personal Access Token (PAT)

This token allows the app repo CI to write to the IaC repo, and allows k3d to pull Docker images from ghcr.io.

GitHub → Settings → Developer settings → Personal access tokens → **Tokens (classic)** → Generate new token (classic):
- Note: `iac-demo`
- Expiration: 90 days
- Scopes — check exactly these two:
  - `repo` (full repo access — needed to create PRs in the IaC repo)
  - `write:packages` (push/pull images on ghcr.io — includes read:packages)

Click Generate token. Copy it — you will not see it again.

---

## Part 2 — Configure secrets locally

### Step 4: Create your local secrets file

```bash
cd /path/to/terraform-helm-chart-project
cp secrets/.env.example secrets/.env
```

Edit `secrets/.env`:
```bash
DB_PASSWORD_DEV=any-password-you-choose
DB_PASSWORD_TEST=any-password-you-choose
DB_PASSWORD_PROD=any-password-you-choose

GITHUB_USERNAME=your-actual-github-username
GITHUB_REPO=terraform-helm-chart-project
GITHUB_TOKEN=ghp_your_token_from_step_3
```

---

## Part 3 — Start the local cluster

### Step 5: Run setup

```bash
bash scripts/setup.sh
```

This script does (in order):
1. Validates your `secrets/.env`
2. Generates `terraform/terraform.tfvars` from `.env`
3. Replaces `YOUR_USERNAME` in Helm values with your real GitHub username
4. Creates the k3d cluster (local Kubernetes in Docker)
5. Runs `terraform init` + `terraform apply` which installs:
   - Traefik (ingress controller)
   - ArgoCD (GitOps engine)
   - Sealed Secrets controller
   - 3 namespaces: `dev`, `test`, `prod`
   - DB password secrets in each namespace
   - ghcr.io pull secret in each namespace
6. Applies ArgoCD app manifests

This takes about 3-5 minutes.

Verify:
```bash
kubectl get namespaces
# Should show: dev, test, prod, argocd

kubectl get pods -n argocd
# All pods should be Running after ~2 min
```

---

## Part 4 — Push the IaC repo to GitHub

### Step 6: Push this repo with all branches

```bash
cd /path/to/terraform-helm-chart-project

git init
git add .
git commit -m "Initial IaC setup"

git remote add origin https://github.com/YOUR_USERNAME/terraform-helm-chart-project.git
git branch -M main
git push -u origin main

# Create environment branches (ArgoCD watches these)
git checkout -b dev
git push -u origin dev

git checkout -b test
git push -u origin test

git checkout -b prod
git push -u origin prod

git checkout main
```

ArgoCD watches `dev`, `test`, `prod` branches — one branch per environment. When a branch changes, ArgoCD deploys that environment.

---

## Part 5 — Connect ArgoCD to GitHub

### Step 7: Open the ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open https://localhost:8080 (accept the self-signed cert warning).

Get the password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Login: username `admin`, password from above.

### Step 8: Add your IaC repo to ArgoCD (if private)

If your IaC repo is private, ArgoCD needs credentials to pull from it.

ArgoCD UI → Settings → Repositories → Connect Repo:
- Type: HTTPS
- URL: `https://github.com/YOUR_USERNAME/terraform-helm-chart-project.git`
- Username: your GitHub username
- Password: your PAT from Step 3

Click Connect. It should show green/Successful.

If the repo is public, skip this step.

---

## Part 6 — Set up the app repo CI

### Step 9: Copy CI workflow to your Java app repo

```bash
cd /path/to/your-java-app

mkdir -p .github/workflows
cp /path/to/terraform-helm-chart-project/app-repo-ci/ci.yml .github/workflows/ci.yml
```

### Step 10: Add secrets and variables to the app repo

App repo on GitHub → Settings → Secrets and variables → Actions:

**Secrets tab:**
| Name | Value |
|------|-------|
| `IAC_REPO_TOKEN` | Your PAT from Step 3 |

**Variables tab:**
| Name | Value |
|------|-------|
| `IAC_REPO` | `YOUR_USERNAME/terraform-helm-chart-project` |

`GITHUB_TOKEN` is automatic — GitHub provides it, no action needed.

### Step 11: Push your Java app to GitHub

```bash
cd /path/to/your-java-app

git init
git add .
git commit -m "Initial commit"
git remote add origin https://github.com/YOUR_USERNAME/java-app.git
git branch -M main
git push -u origin main
```

This push triggers the CI pipeline automatically.

---

## Part 7 — Watch the full pipeline run

### What happens after pushing the app

**GitHub Actions (app repo):**
1. `test` job — runs `mvn test` with PostgreSQL. Takes ~1-2 min.
2. `build` job — builds JAR, builds Docker image, pushes to `ghcr.io/YOUR_USERNAME/java-app:1.0.0-abc1234`
3. `promote` job — clones IaC repo, updates `values-dev.yaml` image tag, opens PR to `dev` branch, auto-merges

Watch it: App repo → Actions tab → click the running workflow.

**GitHub (IaC repo):**
- You can see the auto-merged PR in the IaC repo Pull Requests tab

**ArgoCD (local):**
- ArgoCD detects the change in the `dev` branch within ~3 minutes
- `java-app-dev` and `postgresql-dev` show as Syncing, then Healthy

Watch it:
```bash
kubectl get pods -n dev -w
# Pods appear as ArgoCD deploys them
```

Or in ArgoCD UI at https://localhost:8080.

---

## Part 8 — Promote dev → test

Two ways:

**Option A — GitHub Actions (recommended for demo):**

IaC repo → Actions tab → "Promote dev → test" → Run workflow → Run.

This creates a PR from `dev` into `test`, which you can review and merge. ArgoCD then auto-deploys to the test namespace.

**Option B — Manual:**
```bash
cd /path/to/terraform-helm-chart-project
git checkout test
git merge dev
git push origin test
git checkout main
```

Verify test is running:
```bash
kubectl get pods -n test
kubectl port-forward svc/java-app-test -n test 9092:8080
curl http://localhost:9092/api/info
```

---

## Part 9 — Promote test → prod (manual Sync required)

IaC repo → Actions tab → "Promote test → prod" → Run workflow:
- Enter a reason: `Demo release v1.0.0`
- Click Run

This creates a PR from `test` into `prod`. Merge the PR.

**ArgoCD will NOT auto-deploy prod.** This is intentional — prod has no auto-sync. You must go to the ArgoCD UI and click Sync manually.

ArgoCD UI → `java-app-prod` → click **Sync** → Synchronize.

```bash
kubectl get pods -n prod
```

---

## Part 10 — Teardown

When the demo is done:

```bash
bash scripts/teardown.sh
```

This runs `terraform destroy` then deletes the k3d cluster. Everything local is gone.

The GitHub repos and ghcr.io images remain — delete them manually on GitHub if needed.

To start fresh:
```bash
bash scripts/setup.sh
```

---

## Quick reference

```bash
# Start cluster
bash scripts/setup.sh

# ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# then open https://localhost:8080

# ArgoCD password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Check pods per environment
kubectl get pods -n dev
kubectl get pods -n test
kubectl get pods -n prod

# Port-forward to test an env locally
kubectl port-forward svc/java-app-dev  -n dev  9091:8080
kubectl port-forward svc/java-app-test -n test 9092:8080
kubectl port-forward svc/java-app-prod -n prod 9093:8080

# Then curl
curl http://localhost:9091/api/info

# Tear everything down
bash scripts/teardown.sh
```

---

## Troubleshooting

**ArgoCD apps stuck on Unknown/Missing**
- The IaC repo branches must exist on GitHub (Step 6)
- If repo is private, ArgoCD must have credentials (Step 8)

**CI fails at build step**
- Check app repo has `IAC_REPO_TOKEN` secret and `IAC_REPO` variable (Step 10)
- Check the PAT has Contents + Pull requests write access on the IaC repo

**Pods not starting (ImagePullBackOff)**
- If repo is private: Terraform created `ghcr-pull-secret` in each namespace — check it exists:
  `kubectl get secret ghcr-pull-secret -n dev`
- If it is missing, re-run `terraform apply` from the terraform directory

**kubectl: no cluster**
- Cluster was deleted or Docker restarted: `bash scripts/setup.sh` to recreate
