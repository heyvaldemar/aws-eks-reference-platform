#!/usr/bin/env bash
# tests/eks/run.sh - what a validation run (ADR 10) proves on a real EKS
# cluster, against the cluster in the current kubeconfig and the AWS account
# in the current credentials.
#
# The kind suite (tests/e2e/run.sh) proves the platform's behaviour; this
# proves the parts kind cannot have: the AWS integrations and the node and
# control-plane posture Terraform promises.
#
#   1. every Argo CD Application Synced and Healthy
#   2. admission: each planted violation refused, the control admitted
#      (the same plants as the kind suite)
#   3. nodes: IMDSv2 required with a metadata hop limit of one, on every
#      instance in the cluster
#   4. DNS: ExternalDNS wrote demo.<domain> into the zone (Pod Identity)
#   5. TLS: cert-manager answered a DNS-01 challenge in the zone (Pod
#      Identity), and the network load balancer serves Let's Encrypt's
#      certificate for demo.<domain>
#   6. Karpenter: its NodePool and EC2NodeClass are Ready
#   7. backup: a Velero backup of the demo tenant completes and its objects
#      are in the bucket (Pod Identity)
#
# Needs kubectl, aws, openssl and python3. Env: DOMAIN, ZONE_ID, CLUSTER_NAME,
# VELERO_BUCKET. Writes a summary to $GITHUB_STEP_SUMMARY when it is set.
# The check functions are passed to until_true by name.
# shellcheck disable=SC2329
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
: "${DOMAIN:?}" "${ZONE_ID:?}" "${CLUSTER_NAME:?}" "${VELERO_BUCKET:?}"
HOST="demo.$DOMAIN"
results=()
failed=0
pass() { results+=("PASS  $1"); printf '  ok    %s\n' "$1"; }
fail() { results+=("FAIL  $1"); printf '  FAIL  %s\n' "$1"; failed=1; }
step() { printf '\n== %s\n' "$*"; }
until_true() {  # until_true <seconds> <command...>
  local deadline=$(( $(date +%s) + $1 )); shift
  until "$@"; do [ "$(date +%s)" -ge "$deadline" ] && return 1; sleep 10; done
}

# --- 1 -----------------------------------------------------------------------
step "1. every Argo CD Application Synced and Healthy"
if out="$("$HERE/../../scripts/wait-for-platform.sh" 60 2>&1)"; then
  pass "every Application Synced and Healthy"
else
  fail "not every Application is Synced and Healthy: $(tail -5 <<<"$out")"
fi

# --- 2 -----------------------------------------------------------------------
step "2. admission: each planted violation refused, the control admitted"
for plant in "$HERE"/../e2e/plants/*.yaml; do
  name="$(basename "$plant" .yaml)"
  expect="$(sed -n 's/^# expect: //p' "$plant")"
  out="$(kubectl apply --dry-run=server -f "$plant" 2>&1)"; rc=$?
  if [ "$expect" = admitted ]; then
    if [ $rc -eq 0 ]; then pass "$name: admitted"; else fail "$name was refused: $out"; fi
  elif [ $rc -ne 0 ] && grep -q "$expect" <<<"$out"; then
    pass "$name: refused by $expect"
  else
    fail "$name: expected a refusal by '$expect', got (rc=$rc): ${out:0:200}"
  fi
done

# --- 3 -----------------------------------------------------------------------
step "3. nodes: IMDSv2 and a metadata hop limit of one"
meta="$(aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,MetadataOptions.HttpTokens,MetadataOptions.HttpPutResponseHopLimit]' \
  --output text 2>&1)"
if [ -z "$meta" ]; then
  fail "no running instance carries kubernetes.io/cluster/$CLUSTER_NAME=owned"
elif awk '$2 != "required" || $3 != 1 {bad=1} END {exit bad}' <<<"$meta"; then
  pass "$(wc -l <<<"$meta" | tr -d ' ') instances, every one IMDSv2-only with hop limit 1"
else
  fail "an instance allows IMDSv1 or a hop limit above 1: $(awk '$2 != "required" || $3 != 1' <<<"$meta" | head -3)"
fi

# --- 4 -----------------------------------------------------------------------
step "4. DNS: ExternalDNS wrote demo.$DOMAIN into the zone"
record() {
  aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[?Name=='$HOST.'].Type" --output text 2>/dev/null | grep -qE 'A|CNAME'
}
if until_true 600 record; then pass "$HOST is in the zone"; else fail "no record for $HOST in zone $ZONE_ID after 10 minutes"; fi

# --- 5 -----------------------------------------------------------------------
step "5. TLS: a Let's Encrypt certificate, through the network load balancer"
cert_ready() {
  kubectl -n gateway get certificate -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -qx True
}
if until_true 900 cert_ready; then pass "the Gateway's certificate is Ready (DNS-01 answered in the zone)"; else
  fail "the Gateway's certificate is not Ready after 15 minutes: $(kubectl -n gateway get certificate,certificaterequest,order,challenge 2>&1 | tail -6)"; fi
lb="$(kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=platform \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
issuer=""
served() { issuer="$(openssl s_client -connect "$lb:443" -servername "$HOST" </dev/null 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)"; grep -qi "Let's Encrypt\|(STAGING)" <<<"$issuer"; }
if [ -n "$lb" ] && until_true 600 served; then pass "the load balancer serves $HOST with $issuer"; else
  fail "the load balancer (${lb:-none}) does not serve a Let's Encrypt certificate for $HOST: ${issuer:-no certificate}"; fi

# --- 6 -----------------------------------------------------------------------
step "6. Karpenter: NodePool and EC2NodeClass Ready"
ready() { kubectl get "$1" -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null; }
for kind in nodepools.karpenter.sh ec2nodeclasses.karpenter.k8s.aws; do
  out="$(ready "$kind")"
  if [ -n "$out" ] && ! grep -qv '=True$' <<<"$out"; then pass "$kind: $(tr '\n' ' ' <<<"$out")"; else fail "$kind not Ready: ${out:-none}"; fi
done

# --- 7 -----------------------------------------------------------------------
step "7. backup: a Velero backup completes and lands in the bucket"
backup="eks-validation-$(date +%s)"
kubectl apply -f - >/dev/null <<YAML
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: $backup
  namespace: velero
spec:
  includedNamespaces: [demo]
  defaultVolumesToFsBackup: true
  ttl: 1h
YAML
phase=""
backup_done() { phase="$(kubectl -n velero get backup "$backup" -o jsonpath='{.status.phase}' 2>/dev/null)"; [ "$phase" = Completed ] || [ "$phase" = Failed ] || [ "$phase" = PartiallyFailed ]; }
until_true 900 backup_done
if [ "$phase" = Completed ]; then
  objects="$(aws s3 ls "s3://$VELERO_BUCKET/" --recursive 2>/dev/null | grep -c "$backup" || true)"
  if [ "${objects:-0}" -gt 0 ]; then pass "backup $backup Completed, $objects objects in $VELERO_BUCKET"; else
    fail "backup $backup says Completed but nothing named for it is in $VELERO_BUCKET"; fi
else
  fail "backup $backup ended ${phase:-without a phase}: $(kubectl -n velero get backup "$backup" -o jsonpath='{.status}' 2>&1 | head -c 300)"
fi

# --- summary -------------------------------------------------------------------
printf '\n'
printf '%s\n' "${results[@]}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### EKS validation checks"; echo; echo '```'; printf '%s\n' "${results[@]}"; echo '```'; } >>"$GITHUB_STEP_SUMMARY"
fi
exit "$failed"
