# Entry points of the deployment. Run `make` to list the targets.
# The cluster defaults to ours: override it for another one, e.g. `make start AKS_CLUSTER=my-aks`.

AKS_RESOURCE_GROUP ?= bernstein-rg
AKS_CLUSTER        ?= bernstein-aks
NAMESPACE          := bernstein

AKS := --resource-group $(AKS_RESOURCE_GROUP) --name $(AKS_CLUSTER)

.DEFAULT_GOAL := help
.PHONY: help start stop credentials status build-push deploy all addresses watch rebalance

help: ## List the targets
	@awk 'BEGIN { FS = ":.*## " } /^[a-z-]+:.*## / { printf "  %-12s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

start: ## Start the AKS cluster (if stopped), fetch its kubectl credentials and spread the pods
	@if [ "$$(az aks show $(AKS) --query powerState.code -o tsv)" = Running ]; then \
	  echo "==> $(AKS_CLUSTER) is already running"; \
	else \
	  echo "==> Starting $(AKS_CLUSTER)"; az aks start $(AKS); \
	fi
	@$(MAKE) --no-print-directory credentials
	@scripts/rebalance.sh

stop: ## Stop the AKS cluster, so it no longer uses credits
	@if [ "$$(az aks show $(AKS) --query powerState.code -o tsv)" = Stopped ]; then \
	  echo "==> $(AKS_CLUSTER) is already stopped"; \
	else \
	  echo "==> Stopping $(AKS_CLUSTER)"; az aks stop $(AKS); \
	fi

credentials: ## Point kubectl to the AKS cluster
	az aks get-credentials $(AKS) --overwrite-existing

status: ## Show the cluster power state and the application pods
	@state="$$(az aks show $(AKS) --query powerState.code -o tsv)"; \
	echo "==> $(AKS_CLUSTER): $$state"; \
	if [ "$$state" = Running ]; then kubectl get pods,services --namespace $(NAMESPACE) --request-timeout=10s; fi

build-push: ## Build and push the images (only some of them with SERVICES="poll worker")
	scripts/build-push.sh $(SERVICES)

deploy: ## Deploy the application to the cluster
	scripts/deploy.sh

all: build-push deploy ## Build, push and deploy

addresses: ## Show the external addresses of the application
	@kubectl get services --namespace $(NAMESPACE) \
	  -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}: http://{.status.loadBalancer.ingress[0].ip}{"\n"}{end}'

watch: ## Request the pages continuously and count the errors (run it during an update)
	@scripts/watch.sh

rebalance: ## Spread the replicas over the nodes again (done by start)
	@scripts/rebalance.sh
