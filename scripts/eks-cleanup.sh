#!/usr/bin/env bash
# eks-cleanup.sh - delete what controllers inside the cluster created in AWS,
# before Terraform destroys the network under them.
#
# Load balancers and volumes are made by the AWS Load Balancer Controller and
# the EBS CSI driver, not by Terraform: destroying the VPC under them fails,
# or leaves them billing. They go first, while the controllers that made them
# still run. Argo CD would recreate what it manages, so the root Application
# is deleted first and the Gateway's and the demo's Applications are deleted
# with their resources. Used by `make eks-down` and by the validation run.
set -uo pipefail
kubectl -n argocd delete application platform --wait=false
kubectl -n argocd patch application envoy-gateway demo --type merge \
  -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}'
kubectl -n argocd delete application demo envoy-gateway --timeout=10m
kubectl delete svc -A -l gateway.envoyproxy.io/owning-gateway-name=platform --timeout=10m
kubectl delete pvc -A --all --timeout=10m
# Every step above is best effort: a missing Application or Service is what
# a second run of this script finds. What is left is the residue search's job.
exit 0
