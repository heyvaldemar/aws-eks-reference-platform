#!/usr/bin/env bash
# aws-controller-cleanup.sh <cluster-name> <before|after> - delete, from AWS's
# side, what controllers inside the cluster created for it, so Terraform can
# destroy the network under them.
#
# The in-cluster cleanup (eks-cleanup.sh) asks the controllers to delete
# their own resources, and that can fail: the seventh validation run deleted
# the AWS Load Balancer Controller with the platform before the Gateway's
# Service, so nothing removed its finalizer, and the network load balancer,
# its security groups and two volumes outlived the cluster and blocked the
# VPC. This finds them by the tags the controllers put on them and deletes
# them directly:
#
#   before   load balancers and target groups tagged elbv2.k8s.aws/cluster;
#            run before the cluster is destroyed
#   after    instances Karpenter launched (tagged
#            kubernetes.io/cluster/<name>=owned, not in a Terraform node
#            group), security groups tagged elbv2.k8s.aws/cluster (referenced
#            by the cluster's own security group until the cluster is gone)
#            and volumes tagged kubernetes.io/cluster/<name>=owned that are no
#            longer attached; run after the cluster is destroyed and before
#            the VPC is
#
# Prints what it deletes. Exits non-zero if something tagged for the cluster
# could not be deleted, so the run says so.
set -uo pipefail
CLUSTER="${1:?cluster-name}"
PHASE="${2:?before or after}"
failed=0

tagged_for_cluster() {  # tagged_for_cluster <elbv2 arn>: exit 0 if it is this cluster's
  aws elbv2 describe-tags --resource-arns "$1" \
    --query "TagDescriptions[].Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='$CLUSTER'][]" --output text | grep -q .
}

case "$PHASE" in
  before)
    for lb in $(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' --output text); do
      tagged_for_cluster "$lb" || continue
      echo "deleting load balancer ${lb#*loadbalancer/}"
      aws elbv2 delete-load-balancer --load-balancer-arn "$lb" || failed=1
      aws elbv2 wait load-balancers-deleted --load-balancer-arns "$lb" || failed=1
    done
    for tg in $(aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupArn' --output text); do
      tagged_for_cluster "$tg" || continue
      echo "deleting target group ${tg#*targetgroup/}"
      aws elbv2 delete-target-group --target-group-arn "$tg" || failed=1
    done
    ;;
  after)
    instances="$(aws ec2 describe-instances --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" \
                   "Name=instance-state-name,Values=pending,running,stopping,stopped" \
                   --query 'Reservations[].Instances[].InstanceId' --output text)"
    if [ -n "$instances" ]; then
      echo "terminating instances $instances"
      # shellcheck disable=SC2086  # one id per word
      aws ec2 terminate-instances --instance-ids $instances >/dev/null || failed=1
      # shellcheck disable=SC2086
      aws ec2 wait instance-terminated --instance-ids $instances || failed=1
    fi
    for sg in $(aws ec2 describe-security-groups --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTER" \
                  --query 'SecurityGroups[].GroupId' --output text); do
      echo "deleting security group $sg"
      # Its network interfaces may still be on their way out.
      deleted=0
      for _ in $(seq 1 20); do
        if aws ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1; then deleted=1; break; fi
        sleep 15
      done
      [ "$deleted" = 1 ] || { echo "  could not delete $sg" >&2; failed=1; }
    done
    for vol in $(aws ec2 describe-volumes --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" \
                   "Name=status,Values=available" --query 'Volumes[].VolumeId' --output text); do
      echo "deleting volume $vol"
      aws ec2 delete-volume --volume-id "$vol" || failed=1
    done
    ;;
  *) echo "usage: aws-controller-cleanup.sh <cluster-name> <before|after>" >&2; exit 2 ;;
esac
exit "$failed"
