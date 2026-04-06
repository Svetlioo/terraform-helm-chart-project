# Secrets Management

Secrets in this project are managed at **two levels**:

## 1. Terraform-managed (recommended for this demo)

Terraform creates the K8s secrets from `terraform.tfvars` (which is gitignored).
This is done in `terraform/main.tf` via `kubernetes_secret` resources.

You only need to:
```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars with your passwords
terraform apply
```

## 2. Sealed Secrets (for production / GitOps)

For a real GitOps workflow where ArgoCD manages everything from Git,
you'd use Sealed Secrets so encrypted secrets can be committed:

```bash
# Install kubeseal CLI
brew install kubeseal

# Create a regular secret YAML (don't commit this!)
kubectl create secret generic java-app-db-secret \
  --namespace dev \
  --from-literal=password='my-secret-pw' \
  --dry-run=client -o yaml > /tmp/secret.yaml

# Encrypt it into a SealedSecret (safe to commit)
kubeseal --format yaml < /tmp/secret.yaml > k8s/secrets/dev/db-sealed-secret.yaml

# Clean up the plaintext
rm /tmp/secret.yaml

# Commit the sealed secret - it's encrypted, safe in Git
git add k8s/secrets/dev/db-sealed-secret.yaml
```

The Sealed Secrets controller (installed by Terraform) decrypts it in-cluster.

## Why not plain K8s Secrets in Git?

K8s Secrets are only base64-encoded, NOT encrypted. Anyone with repo access
can decode them. Sealed Secrets solve this with asymmetric encryption -
only the controller in your cluster has the private key.
