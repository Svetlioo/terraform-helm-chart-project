.PHONY: help setup teardown status lint argocd-ui argocd-password compose-up compose-down seal-secret

CLUSTER_NAME := iac-demo

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## Bootstrap everything: k3d cluster, terraform, ArgoCD
	@bash scripts/setup.sh

teardown: ## Destroy everything
	@bash scripts/teardown.sh

terraform-init: ## Initialize Terraform
	cd terraform && terraform init

terraform-plan: ## Plan Terraform changes
	cd terraform && terraform plan

terraform-apply: ## Apply Terraform configuration
	cd terraform && terraform apply -auto-approve

argocd-password: ## Get ArgoCD admin password
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

argocd-ui: ## Port-forward ArgoCD UI to localhost:8080
	@echo "ArgoCD UI available at https://localhost:8080"
	@echo "Username: admin"
	@echo "Password: $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
	kubectl port-forward svc/argocd-server -n argocd 8080:443

status: ## Show cluster and app status
	@echo "=== Cluster ===" && kubectl cluster-info 2>/dev/null || echo "Cluster not running"
	@echo "\n=== Namespaces ===" && kubectl get ns 2>/dev/null | grep -E 'dev|test|prod|argocd' || true
	@echo "\n=== ArgoCD Apps ===" && kubectl get applications -n argocd 2>/dev/null || true
	@echo "\n=== Pods (all envs) ===" && kubectl get pods -A 2>/dev/null | grep -E 'dev|test|prod' || true

lint: ## Lint Helm charts
	helm lint helm/java-app/ -f helm/java-app/values-dev.yaml
	helm lint helm/java-app/ -f helm/java-app/values-test.yaml
	helm lint helm/java-app/ -f helm/java-app/values-prod.yaml
	helm lint helm/postgresql/ -f helm/postgresql/values-dev.yaml
	helm lint helm/postgresql/ -f helm/postgresql/values-test.yaml
	helm lint helm/postgresql/ -f helm/postgresql/values-prod.yaml

ci-local: ## Run CI pipeline locally using act
	act -j build --container-architecture linux/amd64

secrets-init: ## Create secrets/.env from template (first-time setup)
	@if [ ! -f secrets/.env ]; then \
		cp secrets/.env.example secrets/.env; \
		echo "Created secrets/.env - edit it with your passwords before proceeding."; \
	else \
		echo "secrets/.env already exists."; \
	fi

compose-up: ## Run Java app + PostgreSQL via docker-compose (no K8s)
	docker compose --env-file secrets/.env -f docker/docker-compose.yml up -d

compose-down: ## Stop docker-compose services
	docker compose --env-file secrets/.env -f docker/docker-compose.yml down -v

seal-secret: ## Create a sealed secret. Usage: make seal-secret NS=dev KEY=password VAL=mypass
	@kubectl create secret generic java-app-db-secret \
		--namespace $(NS) --from-literal=$(KEY)='$(VAL)' \
		--dry-run=client -o yaml | kubeseal --format yaml
