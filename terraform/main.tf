# =============================================================================
# K3D Cluster
# =============================================================================

resource "null_resource" "k3d_cluster" {
  provisioner "local-exec" {
    command = <<-EOT
      # Create cluster if it doesn't exist
      if ! k3d cluster list | grep -q ${var.cluster_name}; then
        k3d cluster create ${var.cluster_name} \
          --servers 1 \
          --agents 1 \
          --k3s-arg "--disable=traefik@server:0" \
          --port "8080:80@loadbalancer" \
          --port "8443:443@loadbalancer" \
          --wait
      fi
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "k3d cluster delete iac-demo 2>/dev/null || true"
  }
}

# Wait for cluster to be ready
resource "null_resource" "wait_for_cluster" {
  depends_on = [null_resource.k3d_cluster]

  provisioner "local-exec" {
    command = "kubectl wait --for=condition=Ready nodes --all --timeout=120s --context k3d-${var.cluster_name}"
  }
}

# =============================================================================
# Namespaces
# =============================================================================

resource "kubernetes_namespace" "environments" {
  for_each   = toset(var.environments)
  depends_on = [null_resource.wait_for_cluster]

  metadata {
    name = each.value
    labels = {
      environment = each.value
      managed-by  = "terraform"
    }
  }
}

resource "kubernetes_namespace" "argocd" {
  depends_on = [null_resource.wait_for_cluster]

  metadata {
    name = var.argocd_namespace
    labels = {
      managed-by = "terraform"
    }
  }
}

# =============================================================================
# Secrets (DB passwords + ghcr.io image pull secret per environment)
# =============================================================================

resource "kubernetes_secret" "db_secrets" {
  for_each   = toset(var.environments)
  depends_on = [kubernetes_namespace.environments]

  metadata {
    name      = "java-app-db-secret"
    namespace = each.value
  }

  data = {
    password = var.db_passwords[each.value]
  }
}

# ghcr.io pull secret — allows k3d to pull images from GitHub Container Registry
# Required when the GitHub repo (and therefore ghcr.io images) is private.
resource "kubernetes_secret" "ghcr_pull_secret" {
  for_each   = toset(var.environments)
  depends_on = [kubernetes_namespace.environments]

  metadata {
    name      = "ghcr-pull-secret"
    namespace = each.value
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "ghcr.io" = {
          auth = base64encode("${var.github_username}:${var.github_token}")
        }
      }
    })
  }
}

# =============================================================================
# Install Traefik Ingress Controller (lightweight)
# =============================================================================

resource "helm_release" "traefik" {
  depends_on = [null_resource.wait_for_cluster]

  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  namespace        = "kube-system"
  create_namespace = false
  version          = "26.0.0"

  set {
    name  = "resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "resources.limits.cpu"
    value = "200m"
  }
  set {
    name  = "resources.limits.memory"
    value = "128Mi"
  }
}

# =============================================================================
# ArgoCD
# =============================================================================

resource "helm_release" "argocd" {
  depends_on = [kubernetes_namespace.argocd]

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = var.argocd_namespace
  version          = "5.51.6"
  create_namespace = false

  # Lightweight settings for local development
  set {
    name  = "server.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "server.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "controller.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "controller.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "repoServer.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "repoServer.resources.requests.memory"
    value = "64Mi"
  }
  set {
    name  = "redis.resources.requests.cpu"
    value = "50m"
  }
  set {
    name  = "redis.resources.requests.memory"
    value = "32Mi"
  }
  set {
    name  = "dex.enabled"
    value = "false"
  }
  set {
    name  = "notifications.enabled"
    value = "false"
  }
  set {
    name  = "applicationSet.enabled"
    value = "true"
  }
}

# =============================================================================
# Sealed Secrets Controller
# =============================================================================
# Sealed Secrets lets you encrypt K8s Secrets so they're safe to commit to Git.
# You create a SealedSecret (encrypted), commit it, and the controller in-cluster
# decrypts it into a regular Secret. This way secrets live in Git (auditable,
# versioned) but are never exposed in plaintext in the repo.

resource "helm_release" "sealed_secrets" {
  depends_on = [null_resource.wait_for_cluster]

  name             = "sealed-secrets"
  repository       = "https://bitnami-labs.github.io/sealed-secrets"
  chart            = "sealed-secrets"
  namespace        = "kube-system"
  version          = "2.13.3"

  set {
    name  = "resources.requests.cpu"
    value = "25m"
  }
  set {
    name  = "resources.requests.memory"
    value = "32Mi"
  }
}

# =============================================================================
# ArgoCD Project
# =============================================================================

resource "null_resource" "argocd_project" {
  depends_on = [helm_release.argocd]

  provisioner "local-exec" {
    command = "kubectl apply -f ${path.module}/../argocd/projects/java-app.yaml --context k3d-${var.cluster_name}"
  }
}

# =============================================================================
# ArgoCD Applications (one per environment)
# =============================================================================

resource "null_resource" "argocd_apps" {
  for_each   = toset(var.environments)
  depends_on = [null_resource.argocd_project, kubernetes_secret.db_secrets]

  provisioner "local-exec" {
    command = "kubectl apply -f ${path.module}/../argocd/applications/${each.value}.yaml --context k3d-${var.cluster_name}"
  }
}
