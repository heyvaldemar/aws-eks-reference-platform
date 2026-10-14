# aws-eks-reference-platform
#
#   make up        a kind cluster with the whole platform, from this repository
#   make test      every e2e check against it (tests/e2e/run.sh)
#   make tunnel    reach the Gateway at https://demo.platform.test:8443
#   make down      delete the kind cluster
#   make check     the static checks CI runs, no cluster needed
#
# The EKS targets create AWS resources that cost money by the hour. They
# refuse to run unless CONFIRM_SPEND=yes is on the command line; see
# docs/decisions for what they create and what it costs.
#
#   make eks-plan  DOMAIN=platform.example.com            (no spend: a plan)
#   make eks-up    DOMAIN=platform.example.com CONFIRM_SPEND=yes
#   make eks-down  CONFIRM_SPEND=yes

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

BIN := $(CURDIR)/.cache/bin
export PATH := $(BIN):$(PATH)
CLUSTER := reference-platform
TF := terraform -chdir=terraform

.PHONY: help tools up wait test tunnel ui down check eks-plan eks-up eks-bootstrap eks-down guard-spend

help:
	@sed -n '3,17p' $(MAKEFILE_LIST) | sed 's/^# \{0,1\}//'

tools:
	@./scripts/install-tools.sh >/dev/null

up: tools
	@kind get clusters 2>/dev/null | grep -qx $(CLUSTER) || kind create cluster --config kind/cluster.yaml --wait 120s
	./bootstrap/bootstrap.sh kind
	@$(MAKE) --no-print-directory wait

wait:
	python3 scripts/render.py kind out/kind >/dev/null
	EXPECTED_APPS="$$(python3 -c 'import yaml; print(" ".join(a["metadata"]["name"] for a in yaml.safe_load_all(open("out/kind/_applications.yaml")) if a))')" \
	  ./scripts/wait-for-platform.sh 1500

test: tools
	./tests/e2e/run.sh

tunnel:
	@kubectl -n cert-manager get secret platform-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > platform-ca.crt
	@echo "https://demo.platform.test:8443  (CA: ./platform-ca.crt; add '127.0.0.1 demo.platform.test' to /etc/hosts, or use curl --resolve)"
	kubectl -n envoy-gateway-system port-forward \
	  "svc/$$(kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=platform -o jsonpath='{.items[0].metadata.name}')" 8443:443

ui:
	@echo "Argo CD at https://localhost:8080, user admin, password:"
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
	kubectl -n argocd port-forward svc/argocd-server 8080:443

down:
	kind delete cluster --name $(CLUSTER)

check: tools
	./scripts/validate.sh

# --- EKS: written and tested against a mocked provider; not yet applied ------

guard-spend:
	@if [ "$(CONFIRM_SPEND)" != yes ]; then \
	  echo "This creates AWS resources billed by the hour (about \$$0.32/h before workloads; see README)."; \
	  echo "Run it again with CONFIRM_SPEND=yes if that is what you want."; exit 1; fi

eks-plan:
	@[ -n "$(DOMAIN)" ] || { echo "DOMAIN=platform.example.com is required"; exit 1; }
	$(TF) init -input=false
	$(TF) plan -input=false -var "domain=$(DOMAIN)" \
	  -var 'cluster_endpoint_public_access_cidrs=["$(shell curl -fsS https://checkip.amazonaws.com | tr -d '\n')/32"]'

eks-up: guard-spend
	@[ -n "$(DOMAIN)" ] || { echo "DOMAIN=platform.example.com is required"; exit 1; }
	$(TF) init -input=false
	$(TF) apply -input=false -auto-approve -var "domain=$(DOMAIN)" \
	  -var 'cluster_endpoint_public_access_cidrs=["$(shell curl -fsS https://checkip.amazonaws.com | tr -d '\n')/32"]'
	@$(MAKE) --no-print-directory eks-bootstrap
	@echo "Delegate $(DOMAIN) to these name servers for certificates to issue:"
	@$(TF) output -json name_servers

eks-bootstrap: tools
	eval "$$($(TF) output -raw kubeconfig_command)"
	CLUSTER_NAME="$$($(TF) output -raw cluster_name)" \
	AWS_REGION="$$($(TF) output -raw region)" \
	VPC_ID="$$($(TF) output -raw vpc_id)" \
	DOMAIN="$$($(TF) output -raw domain)" \
	CLUSTER_ISSUER="$$($(TF) output -raw cluster_issuer)" \
	VELERO_BUCKET="$$($(TF) output -raw velero_bucket)" \
	KARPENTER_NODE_ROLE="$$($(TF) output -raw karpenter_node_role)" \
	KARPENTER_INTERRUPTION_QUEUE="$$($(TF) output -raw karpenter_interruption_queue)" \
	  ./bootstrap/bootstrap.sh eks

# Load balancers and volumes are created by controllers inside the cluster,
# not by Terraform; destroying the VPC under them fails, or leaves them
# billing. They go first, while the controllers that made them still run.
eks-down: guard-spend
	./scripts/eks-cleanup.sh
	$(TF) destroy -input=false -auto-approve -var "domain=$$($(TF) output -raw domain)" \
	  -var 'cluster_endpoint_public_access_cidrs=["$(shell curl -fsS https://checkip.amazonaws.com | tr -d '\n')/32"]'
