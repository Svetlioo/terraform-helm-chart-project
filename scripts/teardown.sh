#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="iac-demo"

echo "============================================"
echo "  IaC Demo - Teardown"
echo "============================================"
echo ""

# Terraform destroy
echo "[1/3] Running Terraform destroy..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR/terraform"
if [ -f "terraform.tfstate" ]; then
  terraform destroy -auto-approve 2>/dev/null || true
fi

# Delete cluster
echo ""
echo "[2/2] Deleting k3d cluster..."
k3d cluster delete "$CLUSTER_NAME" 2>/dev/null || true

echo ""
echo "============================================"
echo "  Teardown Complete!"
echo "============================================"
