# App Repository CI Pipeline

Copy `ci.yml` into `.github/workflows/ci.yml` in your **Java app repo** (not this IaC repo).

## What it does

```
push to main
  → tests pass (real PostgreSQL)
  → build JAR + Docker image
  → push image to ghcr.io (free, on GitHub)
  → update values-dev.yaml in IaC repo
  → ArgoCD deploys to dev namespace
```

**One artifact: the Docker image on ghcr.io.** No separate Maven registry needed.

## Setup (5 steps)

**1. Copy the workflow**
```bash
mkdir -p .github/workflows
cp app-repo-ci/ci.yml .github/workflows/ci.yml
```

**2. Create a PAT for the IaC repo**
GitHub → Settings → Developer settings → Fine-grained tokens → New token
- Repository access: your IaC repo only
- Permissions: Contents (read/write), Pull requests (read/write)

**3. Add secret to the app repo**
App repo → Settings → Secrets and variables → Actions → New secret:
- Name: `IAC_REPO_TOKEN`, Value: the PAT from step 2

**4. Add variable to the app repo**
App repo → Settings → Secrets and variables → Actions → Variables tab:
- Name: `IAC_REPO`, Value: `your-username/terraform-helm-chart-project`

**5. Make ghcr.io images accessible**
If your GitHub repo is **private**, the images on ghcr.io are also private.
Terraform already creates a `ghcr-pull-secret` in each namespace using your `GITHUB_TOKEN` from `secrets/.env`.
If your repo is **public**, images are public — no pull secret needed, but Terraform creates it anyway harmlessly.
