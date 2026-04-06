output "cluster_name" {
  description = "Name of the k3d cluster"
  value       = var.cluster_name
}

output "image_registry" {
  description = "Docker image registry used by this project"
  value       = "ghcr.io/${var.github_username}/java-app"
}

output "environments" {
  description = "Created environments"
  value       = var.environments
}

output "argocd_url" {
  description = "ArgoCD UI URL (after port-forward)"
  value       = "https://localhost:8080 (run: make argocd-ui)"
}

output "kubeconfig_context" {
  description = "Kubectl context to use"
  value       = "k3d-${var.cluster_name}"
}
