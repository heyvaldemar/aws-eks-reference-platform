#!/usr/bin/env bash
# eks-cleanup.sh - delete what controllers inside the cluster created in AWS,
# before Terraform destroys the network under them.
#
# Load balancers and volumes are made by the AWS Load Balancer Controller and
# the EBS CSI driver, not by Terraform: destroying the VPC under them fails,
# or leaves them billing. They go first, while the controllers that made them
# still run.
#
# Argo CD is stopped first, not its Applications deleted: deleting the root
# Application cascades through the platform, the load balancer controller
# included, and the seventh validation run lost it that way before the
# Gateway's Service was gone, so the load balancer outlived the cluster.
# Stopped, Argo CD neither cascades nor puts back what is deleted below.
# scripts/aws-controller-cleanup.sh then deletes from AWS's side whatever
# this could not. Used by `make eks-down` and by the validation run.
set -uo pipefail
kubectl -n argocd scale statefulset argocd-application-controller --replicas=0
kubectl -n argocd scale deployment argocd-applicationset-controller --replicas=0
kubectl -n argocd wait --for=delete pod -l app.kubernetes.io/name=argocd-application-controller --timeout=2m

# Gateways first: Envoy Gateway owns the Service in front of each, and would
# put a deleted Service back while its Gateway exists. Then every Service of
# type LoadBalancer that is left, while the load balancer controller runs.
kubectl delete gateways.gateway.networking.k8s.io -A --all --timeout=10m
for _ in $(seq 1 30); do
  kubectl get svc -A -l gateway.envoyproxy.io/owning-gateway-name -o name 2>/dev/null | grep -q . || break
  sleep 10
done
kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' |
  while read -r ns name; do
    [ -n "$name" ] && kubectl -n "$ns" delete svc "$name" --timeout=10m
  done
kubectl delete ingress -A --all --timeout=10m

# Nodes Karpenter launched are EC2 instances Terraform never made: Karpenter
# terminates them when their NodeClaims go, while it still runs.
kubectl delete nodepools.karpenter.sh --all --timeout=5m
kubectl delete nodeclaims.karpenter.sh --all --timeout=10m

# Volumes: the claims go, and the EBS CSI driver deletes a volume once nothing
# mounts it. A volume still mounted when the nodes go is left available, and
# aws-controller-cleanup.sh deletes it after the cluster.
kubectl delete pvc -A --all --wait=false
# Every step above is best effort: what is left is the AWS-side cleanup's and
# then the residue search's job.
exit 0
