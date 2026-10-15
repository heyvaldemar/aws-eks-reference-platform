#!/usr/bin/env bash
# aws-residue.sh <run-id> <cluster-name> - what a validation run (ADR 10) left
# behind in the current account and region, after its teardown.
#
# Terraform tags everything it creates with run-id; the Resource Groups
# Tagging API finds those. Controllers inside the cluster create resources
# Terraform never sees, tagged by cluster instead: load balancers, volumes,
# instances, security groups and network interfaces. Both are searched.
# Exits 1 and lists them when anything is found, so the run fails.
#
# The Tagging API keeps answering for a while with what was just deleted (the
# first real run's teardown left nothing, and it listed seven ARNs), and a KMS
# key is only scheduled for deletion. So each tagged ARN is asked about
# directly: gone, deleted or pending deletion is not residue. A type this
# script does not know how to ask about is reported, never assumed gone.
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

# still_there <arn>: exit 0 if the resource exists and is not on its way out.
still_there() {
  local arn="$1" service type id
  service="$(cut -d: -f3 <<<"$arn")"
  type="$(cut -d: -f6- <<<"$arn" | cut -d/ -f1)"
  id="${arn##*/}"
  case "$service:$type" in
    kms:key)
      ! aws kms describe-key --key-id "$id" --query 'KeyMetadata.KeyState' --output text 2>/dev/null \
        | grep -qE '^(PendingDeletion|PendingReplicaDeletion)$' && aws kms describe-key --key-id "$id" >/dev/null 2>&1 ;;
    ec2:natgateway)
      aws ec2 describe-nat-gateways --nat-gateway-ids "$id" --query 'NatGateways[].State' --output text 2>/dev/null \
        | grep -qvE '^(deleted)?$' ;;
    ec2:instance)
      aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[].Instances[].State.Name' --output text 2>/dev/null \
        | grep -qvE '^(terminated)?$' ;;
    ec2:subnet) aws ec2 describe-subnets --subnet-ids "$id" >/dev/null 2>&1 ;;
    ec2:security-group) aws ec2 describe-security-groups --group-ids "$id" >/dev/null 2>&1 ;;
    ec2:vpc) aws ec2 describe-vpcs --vpc-ids "$id" >/dev/null 2>&1 ;;
    ec2:vpc-flow-log) aws ec2 describe-flow-logs --flow-log-ids "$id" --query 'FlowLogs[].FlowLogId' --output text 2>/dev/null | grep -q . ;;
    ec2:route-table) aws ec2 describe-route-tables --route-table-ids "$id" >/dev/null 2>&1 ;;
    ec2:internet-gateway) aws ec2 describe-internet-gateways --internet-gateway-ids "$id" >/dev/null 2>&1 ;;
    ec2:elastic-ip) aws ec2 describe-addresses --allocation-ids "$id" >/dev/null 2>&1 ;;
    ec2:network-interface) aws ec2 describe-network-interfaces --network-interface-ids "$id" >/dev/null 2>&1 ;;
    ec2:volume) aws ec2 describe-volumes --volume-ids "$id" >/dev/null 2>&1 ;;
    ec2:launch-template) aws ec2 describe-launch-templates --launch-template-ids "$id" >/dev/null 2>&1 ;;
    eks:cluster) aws eks describe-cluster --name "$id" >/dev/null 2>&1 ;;
    logs:log-group) aws logs describe-log-groups --log-group-name-prefix "${arn#*:log-group:}" \
                      --query 'logGroups[].logGroupName' --output text 2>/dev/null | tr '\t' '\n' | grep -qxF "${arn#*:log-group:}" ;;
    *) return 0 ;;
  esac
}

tagged=""
for arn in $(aws resourcegroupstaggingapi get-resources --tag-filters "Key=run-id,Values=$RUN_ID" \
               --query 'ResourceTagMappingList[].ResourceARN' --output text); do
  if still_there "$arn"; then tagged+="$arn"$'\n'; else echo "gone, though the Tagging API still lists it: $arn"; fi
done
report "tagged run-id=$RUN_ID" "${tagged%$'\n'}"

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
