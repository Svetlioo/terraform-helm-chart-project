#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="iac-demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "============================================"
echo "  IaC Demo - Full Local Setup"
echo "============================================"
echo ""

# ---- Step 1: Prerequisites ----
echo "[1/7] Checking prerequisites..."
for cmd in docker kubectl k3d helm terraform; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is not installed."
    echo ""
    echo "Install everything with:"
    echo "  brew install docker kubectl k3d helm terraform"
    exit 1
  fi
done
echo "  All prerequisites found."

# ---- Step 2: Secrets ----
echo ""
echo "[2/7] Checking secrets configuration..."
if [ ! -f "$PROJECT_DIR/secrets/.env" ]; then
  echo "  No secrets/.env found. Creating from template..."
  cp "$PROJECT_DIR/secrets/.env.example" "$PROJECT_DIR/secrets/.env"
  echo ""
  echo "  !! ACTION REQUIRED !!"
  echo "  Edit secrets/.env with your passwords, then re-run this script."
  echo "  File: $PROJECT_DIR/secrets/.env"
  exit 1
fi

# Source the secrets
set -a
source "$PROJECT_DIR/secrets/.env"
set +a

# Validate required vars
for var in DB_PASSWORD_DEV DB_PASSWORD_TEST DB_PASSWORD_PROD GITHUB_USERNAME GITHUB_TOKEN; do
  if [ -z "${!var:-}" ] || [[ "${!var}" == *"change-me"* ]] || [[ "${!var}" == "YOUR_USERNAME" ]] || [[ "${!var}" == "ghp_your_token_here" ]]; then
    echo "  ERROR: $var is not set or still has placeholder value in secrets/.env"
    exit 1
  fi
done
echo "  Secrets loaded and validated."

# Generate terraform.tfvars from .env (so there's one source of truth)
cat > "$PROJECT_DIR/terraform/terraform.tfvars" <<EOF
github_repo_url = "https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO:-terraform-helm-chart-project}.git"
github_username = "${GITHUB_USERNAME}"
github_token    = "${GITHUB_TOKEN}"

db_passwords = {
  dev  = "${DB_PASSWORD_DEV}"
  test = "${DB_PASSWORD_TEST}"
  prod = "${DB_PASSWORD_PROD}"
}
EOF
echo "  Generated terraform/terraform.tfvars from secrets/.env"

# Replace YOUR_USERNAME placeholder in Helm values (ghcr.io image repository)
for values_file in "$PROJECT_DIR"/helm/java-app/values-*.yaml; do
  sed -i.bak "s|ghcr.io/YOUR_USERNAME/java-app|ghcr.io/${GITHUB_USERNAME}/java-app|g" "$values_file"
  rm -f "${values_file}.bak"
done
echo "  Updated Helm values with ghcr.io/${GITHUB_USERNAME}/java-app"

# ---- Step 3: Docker ----
echo ""
echo "[3/7] Checking Docker is running..."
if ! docker info &>/dev/null; then
  echo "ERROR: Docker is not running. Please start Docker Desktop."
  exit 1
fi
echo "  Docker is running."

# ---- Step 4: k3d Cluster ----
echo ""
echo "[4/7] Creating k3d cluster..."
if k3d cluster list 2>/dev/null | grep -q "$CLUSTER_NAME"; then
  echo "  Cluster already exists, skipping."
else
  k3d cluster create "$CLUSTER_NAME" \
    --servers 1 \
    --agents 1 \
    --k3s-arg "--disable=traefik@server:0" \
    --port "8080:80@loadbalancer" \
    --port "8443:443@loadbalancer" \
    --wait
  echo "  Cluster created."
fi

echo "  Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# ---- Step 5: Terraform ----
echo ""
echo "[5/7] Running Terraform..."
cd "$PROJECT_DIR/terraform"
terraform init
terraform apply -auto-approve
echo "  Terraform applied."

# ---- Step 6: Update ArgoCD apps with actual repo URL ----
echo ""
echo "[6/7] Updating ArgoCD application manifests with your GitHub repo..."
REPO_URL="https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO:-terraform-helm-chart-project}.git"
for env_file in "$PROJECT_DIR"/argocd/applications/*.yaml; do
  sed -i.bak "s|https://github.com/YOUR_USERNAME/terraform-helm-chart-project.git|${REPO_URL}|g" "$env_file"
  rm -f "${env_file}.bak"
done
kubectl apply -f "$PROJECT_DIR/argocd/applications/"
echo "  ArgoCD apps now point to: $REPO_URL"

# ---- Done ----
echo ""
echo "============================================"
echo "  Setup Complete!"
echo "============================================"
echo ""
kubectl get namespaces | grep -E 'NAME|dev|test|prod|argocd'
echo ""
echo "Next steps:"
echo "  1. Push this repo to GitHub and create branches: dev, test, prod"
echo "     git init && git add . && git commit -m 'Initial setup'"
echo "     git remote add origin https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO:-terraform-helm-chart-project}.git"
echo "     git branch -M main && git push -u origin main"
echo "     git checkout -b dev && git push -u origin dev"
echo "     git checkout -b test && git push -u origin test"
echo "     git checkout -b prod && git push -u origin prod"
echo ""
echo "  2. Access ArgoCD dashboard:"
echo "     kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "     Open https://localhost:8080"
echo "     Username: admin"
echo "     Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "Branching strategy (IaC repo):"
echo "  dev branch   -> ArgoCD auto-deploys to dev  (app repo CI auto-updates this)"
echo "  test branch  -> ArgoCD auto-deploys to test (you merge dev -> test via PR)"
echo "  prod branch  -> ArgoCD deploys to prod      (you merge test -> prod, manual sync)"
