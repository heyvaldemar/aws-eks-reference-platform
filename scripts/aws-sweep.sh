#!/usr/bin/env bash
# aws-sweep.sh - outside every run (ADR 10): with the delete-only role, destroy
# what a validation run left behind for longer than MAX_AGE_HOURS (default 3).
#
# For each run whose state in the bucket still lists resources:
#   1. what controllers made in AWS, found by the cluster's tags
#      (aws-controller-cleanup.sh): load balancers and target groups
#   2. terraform destroy with the run's own variables: the cluster first,
#      then the controllers' instances, security groups and available
#      volumes, then everything else
#   3. the residue search
# Env: TF_STATE_BUCKET, AWS_REGION. Needs aws, terraform and python3.
set -uo pipefail
BUCKET="${TF_STATE_BUCKET:?}"
: "${AWS_REGION:?}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-3}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
now="$(date +%s)"
failed=0

keys="$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix runs/ \
  --query 'Contents[].Key' --output text 2>/dev/null | tr '\t' '\n' | grep '\.tfstate$' || true)"
[ -n "$keys" ] || { echo "no run states in $BUCKET"; exit 0; }

for key in $keys; do
  run="${key#runs/}"; run="${run%.tfstate}"
  cluster="reference-platform-$run"
  aws s3 cp --quiet "s3://$BUCKET/$key" "$WORK/state.json" || { echo "run $run: state unreadable"; failed=1; continue; }
  left="$(python3 -c 'import json,sys; print(sum(len(r.get("instances", [])) for r in json.load(open(sys.argv[1])).get("resources", []) if r.get("mode") == "managed"))' "$WORK/state.json")"
  [ "$left" -gt 0 ] || continue
  modified="$(aws s3api head-object --bucket "$BUCKET" --key "$key" --query LastModified --output text)"
  age_h=$(( (now - $(date -d "$modified" +%s)) / 3600 ))
  if [ "$age_h" -lt "$MAX_AGE_HOURS" ]; then
    echo "run $run: $left resources, state $age_h h old: still inside its run, left alone"
    continue
  fi
  echo "run $run: $left resources left for $age_h h: sweeping"

  # 1. What controllers made, by the cluster's tags: load balancers and
  #    target groups now; their security groups, instances and volumes once
  #    the cluster is gone (step 2), since the cluster's own security group
  #    references them until then. The same script the run's teardown uses.
  "$HERE/aws-controller-cleanup.sh" "$cluster" before || failed=1

  # 2. terraform destroy with the run's own variables. The API address only
  #    has to be valid; nothing reaches the API during a destroy.
  if aws s3 cp --quiet "s3://$BUCKET/runs/$run.tfvars.json" "$WORK/run.tfvars.json"; then
    rm -rf "$HERE/../terraform/.terraform"
    printf 'terraform {\n  backend "s3" {}\n}\n' > "$HERE/../terraform/ci_backend.tf"
    if terraform -chdir="$HERE/../terraform" init -input=false -reconfigure -lockfile=readonly \
         -backend-config="bucket=$BUCKET" -backend-config="key=$key" \
         -backend-config="region=$AWS_REGION" -backend-config="use_lockfile=true" >/dev/null &&
       terraform -chdir="$HERE/../terraform" destroy -input=false -auto-approve -target=aws_eks_cluster.this \
         -var-file="$WORK/run.tfvars.json" -var 'cluster_endpoint_public_access_cidrs=["198.51.100.1/32"]' &&
       { "$HERE/aws-controller-cleanup.sh" "$cluster" after || failed=1; } &&
       terraform -chdir="$HERE/../terraform" destroy -input=false -auto-approve -var-file="$WORK/run.tfvars.json" \
         -var 'cluster_endpoint_public_access_cidrs=["198.51.100.1/32"]'; then
      echo "run $run: destroyed"
    else
      echo "run $run: terraform destroy failed"; failed=1
    fi
  else
    echo "run $run: no variables beside the state; only the controllers' resources were removed"; failed=1
  fi

  # 3. What is still there.
  "$HERE/aws-residue.sh" "$run" "$cluster" || failed=1
done
exit "$failed"
