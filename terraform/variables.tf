variable "cluster_name" {
  description = "Name of the k3d cluster"
  type        = string
  default     = "iac-demo"
}

variable "environments" {
  description = "List of environments to create"
  type        = list(string)
  default     = ["dev", "test", "prod"]
}

variable "github_username" {
  description = "GitHub username — used to create the ghcr.io image pull secret"
  type        = string
}

variable "github_token" {
  description = "GitHub Personal Access Token with read:packages scope — allows k3d to pull images from ghcr.io"
  type        = string
  sensitive   = true
}

variable "argocd_namespace" {
  description = "Namespace for ArgoCD"
  type        = string
  default     = "argocd"
}

variable "db_passwords" {
  description = "Database passwords per environment. Provide via terraform.tfvars or TF_VAR_db_passwords"
  type        = map(string)
  sensitive   = true
  # No default - must be provided at apply time
}

variable "github_repo_url" {
  description = "GitHub repository URL for ArgoCD to watch"
  type        = string
  # No default - must be provided
}
