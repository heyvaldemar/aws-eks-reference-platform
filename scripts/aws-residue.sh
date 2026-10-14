#!/usr/bin/env bash
# aws-residue.sh <run-id> <cluster-name> - what a validation run (ADR 10) left
# behind in the current account and region, after its teardown.
#
# Terraform tags everything it creates with run-id; the Resource Groups
# Tagging API finds those. Controllers inside the cluster create resources
# Terraform never sees, tagged by cluster instead: load balancers, volumes,
# instances, security groups and network interfaces. Both are searched.
# Exits 1 and lists them when anything is found, so the run fails.
set -uo pipefail
RUN_ID="${1:?run-id}"
CLUSTER="${2:?cluster-name}"
found=0
report() {  # report <label> <lines>
  [ -n "$2" ] || return 0
  found=1
  printf '%s\n' "$1:"
  while IFS= read -r line; do printf '  %s\n' "$line"; done <<<"$2"
}

report "tagged run-id=$RUN_ID" "$(aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=run-id,Values=$RUN_ID" --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' | sed '/^$/d')"

report "instances of $CLUSTER not terminated" "$(aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name]' --output text)"

report "volumes of $CLUSTER" "$(aws ec2 describe-volumes \
  --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" \
  --query 'Volumes[].[VolumeId,Size,State]' --output text)"

report "network interfaces of $CLUSTER" "$(aws ec2 describe-network-interfaces \
  --filters "Name=tag:cluster.k8s.amazonaws.com/name,Values=$CLUSTER" \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,Status]' --output text)"

report "security groups of $CLUSTER" "$(aws ec2 describe-security-groups \
  --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" \
  --query 'SecurityGroups[].[GroupId,GroupName]' --output text)"

lbs="$(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' --output text | tr '\t' '\n' | sed '/^$/d')"
lb_left=""
for arn in $lbs; do
  if aws elbv2 describe-tags --resource-arns "$arn" \
       --query "TagDescriptions[].Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='$CLUSTER'][]" --output text | grep -q .; then
    lb_left+="$arn"$'\n'
  fi
done
report "load balancers of $CLUSTER" "${lb_left%$'\n'}"

if [ "$found" -eq 0 ]; then
  echo "nothing left from run $RUN_ID (cluster $CLUSTER)"
fi
exit "$found"
