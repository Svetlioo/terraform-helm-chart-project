provider "kubernetes" {
  config_path = "~/.kube/config"
  config_context = "k3d-${var.cluster_name}"
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
    config_context = "k3d-${var.cluster_name}"
  }
}
