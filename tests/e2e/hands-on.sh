#!/usr/bin/env bash
# tests/e2e/hands-on.sh - run docs/hands-on.md's three exercises and check
# that each break shows the symptom the guide describes, that the guide's
# diagnosis finds it, and that its fix fixes it.
#
# A guide nobody runs drifts from the platform it describes. This runs the
# same commands, in the same order, on a kind cluster with the platform up
# (.github/workflows/hands-on.yml, weekly and on any change to the guide).
#
# Needs kubectl, curl, python3, and the platform Synced and Healthy.
#
# `condition && pass ... || fail ...` is used throughout: pass only appends
# to an array and prints, so fail runs exactly when the condition fails.
# Single-quoted `bash -c` strings are expanded by that inner shell on purpose.
# shellcheck disable=SC2015,SC2016
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
PF_PID=""
RUN="$(date +%s)"
results=()
failed=0

pass() { results+=("PASS  $1"); printf '  ok    %s\n' "$1"; }
fail() { results+=("FAIL  $1"); printf '  FAIL  %s\n' "$1"; failed=1; }
step() { printf '\n== %s\n' "$*"; }
autosync() {  # autosync <app> on|off
  if [ "$2" = on ]; then
    kubectl -n argocd patch application "$1" --type merge \
      -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null
  else
    kubectl -n argocd patch application "$1" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
  fi
}
until_true() {  # until_true <seconds> <command...>: retry every 5s
  local deadline=$(( $(date +%s) + $1 )); shift
  until "$@"; do [ "$(date +%s)" -ge "$deadline" ] && return 1; sleep 5; done
}

# shellcheck disable=SC2329  # called by the EXIT trap
cleanup() {
  for app in policies demo kyverno; do autosync "$app" on 2>/dev/null; done
  [ -n "$PF_PID" ] && { kill "$PF_PID"; wait "$PF_PID"; } 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# The guide's `make tunnel`: the Gateway on localhost:8443, the platform CA.
tunnel() {
  local svc
  [ -n "$PF_PID" ] && { kill "$PF_PID"; wait "$PF_PID"; } 2>/dev/null
  svc="$(kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=platform -o jsonpath='{.items[0].metadata.name}')"
  kubectl -n envoy-gateway-system port-forward "svc/$svc" 8443:443 >/dev/null 2>&1 &
  PF_PID=$!
  until_true 30 bash -c '(exec 3<>/dev/tcp/127.0.0.1/8443) 2>/dev/null'
}
code() {  # code [curl args]: the HTTP status the demo answers with
  kill -0 "$PF_PID" 2>/dev/null || tunnel
  curl -s -o "$WORK/body" -w '%{http_code}' --max-time 30 --cacert "$WORK/platform-ca.crt" \
    --resolve demo.platform.test:8443:127.0.0.1 "$@" 2>/dev/null
}
kubectl -n cert-manager get secret platform-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >"$WORK/platform-ca.crt"
tunnel

step "0. the demo answers"
[ "$(code https://demo.platform.test:8443/)" = 200 ] && pass "https://demo.platform.test:8443 answers 200" \
  || fail "the demo does not answer before any exercise"

# --- 1 ------------------------------------------------------------------------
step "1. warm-up: two layers of admission"
out="$(kubectl -n demo run tag-only --image=ghcr.io/stefanprodan/podinfo:6.15.0 --restart=Never 2>&1)"
if grep -q "violates PodSecurity" <<<"$out"; then pass "a bare pod is refused by Pod Security first"; else
  fail "a bare tag-only pod was not refused by Pod Security: $out"; kubectl -n demo delete pod tag-only --ignore-not-found >/dev/null; fi
out="$(kubectl apply --dry-run=server -f "$HERE/plants/tag-only-image.yaml" 2>&1)"
grep -q "vpol-require-image-digest" <<<"$out" && pass "a Pod Security-clean pod with a tag is refused by vpol-require-image-digest" \
  || fail "the tag-only plant was not refused by vpol-require-image-digest: $out"
kubectl apply --dry-run=server -f "$HERE/plants/compliant-pod.yaml" >/dev/null 2>&1 && pass "its compliant twin is admitted" \
  || fail "the compliant plant was refused"

step "1. a policy change stops every deploy"
autosync policies off
kubectl patch validatingpolicy require-probes --type json -p '[{"op":"replace","path":"/spec/validations/0/expression",
  "value":"object.spec.template.spec.containers.all(c, has(c.readinessProbe) && has(c.livenessProbe) && has(c.startupProbe))"}]' >/dev/null
until_true 120 bash -c "kubectl get validatingadmissionpolicy vpol-require-probes -o jsonpath='{.spec.validations[0].expression}' | grep -q startupProbe" \
  || fail "the stricter policy never reached the API server"
out="$(kubectl -n demo rollout restart deployment/frontend 2>&1)"
grep -q "vpol-require-probes" <<<"$out" && pass "a restart of the demo is refused, naming vpol-require-probes" \
  || fail "the restart was not refused by vpol-require-probes: $out"
kubectl get validatingadmissionpolicy vpol-require-probes -o jsonpath='{.spec.validations[0].expression}' | grep -q startupProbe && pass "the live policy asks for a startupProbe" || fail "the live policy does not show the change"
git -C "$ROOT" show HEAD:policies/require-probes.yaml | grep -q startupProbe \
  && fail "Git's policy also asks for a startupProbe, so the diagnosis would find no difference" \
  || pass "the policy in Git does not, which is the difference the guide points at"
until_true 120 bash -c '[ "$(kubectl -n argocd get application policies -o jsonpath="{.status.sync.status}")" = OutOfSync ]' \
  && pass "Argo CD reports the policies Application OutOfSync" || fail "Argo CD never reported the policies OutOfSync"
autosync policies on
until_true 180 bash -c "! kubectl get validatingadmissionpolicy vpol-require-probes -o jsonpath='{.spec.validations[0].expression}' | grep -q startupProbe" \
  && pass "turning auto-sync back on restores the policy from Git" || fail "the policy was not restored from Git"
if kubectl -n demo rollout restart deployment/frontend >/dev/null 2>&1 && kubectl -n demo rollout status deployment/frontend --timeout=300s >/dev/null; then
  pass "the demo deploys again"; else fail "the demo still does not deploy after the fix"; fi

# --- 2 ------------------------------------------------------------------------
step "2. the site returns 503"
autosync demo off
kubectl -n demo patch networkpolicy allow-from-gateway --type json \
  -p '[{"op":"replace","path":"/spec/ingress/0/ports/0/port","value":9899}]' >/dev/null
until_true 90 bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 --cacert '$WORK/platform-ca.crt' --resolve demo.platform.test:8443:127.0.0.1 https://demo.platform.test:8443/)\" = 503 ]" \
  && pass "the demo answers 503" || fail "the broken NetworkPolicy did not produce a 503"
[ "$(kubectl -n demo get httproute demo -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')" = True ] \
  && pass "the route is still Accepted" || fail "the route is not Accepted, so the guide's first check would mislead"
[ -n "$(kubectl -n demo get endpointslices -l kubernetes.io/service-name=frontend -o jsonpath='{.items[0].endpoints[0].addresses[0]}')" ] \
  && pass "the frontend still has ready endpoints" || fail "the frontend has no endpoints"
kubectl -n demo describe networkpolicy allow-from-gateway | grep -q "9899" \
  && pass "describe shows the port the pods do not listen on" || fail "describe does not show the broken port"
autosync demo on
until_true 180 bash -c '[ "$(kubectl -n demo get networkpolicy allow-from-gateway -o jsonpath="{.spec.ingress[0].ports[0].port}")" = 9898 ]' \
  && pass "turning auto-sync back on restores the policy from Git" || fail "the NetworkPolicy was not restored"
until_true 90 bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 --cacert '$WORK/platform-ca.crt' --resolve demo.platform.test:8443:127.0.0.1 https://demo.platform.test:8443/)\" = 200 ]" \
  && pass "the demo answers 200 again" || fail "the demo did not recover"
kubectl -n demo delete networkpolicy default-deny >/dev/null
until_true 120 kubectl -n demo get networkpolicy default-deny >/dev/null 2>&1 \
  && pass "Kyverno puts a deleted default-deny back" || fail "default-deny did not come back"

# --- 3 ------------------------------------------------------------------------
step "3. a restore that said Completed"
hash="$(curl -s --max-time 30 --cacert "$WORK/platform-ca.crt" --resolve demo.platform.test:8443:127.0.0.1 \
  -X POST --data "written before the incident" https://demo.platform.test:8443/store | python3 -c 'import json,sys; print(json.load(sys.stdin)["hash"])' 2>/dev/null)"
[ -n "$hash" ] && pass "a marker is written" || fail "could not write the marker"
backup() {  # backup <name> <true|false>: one at a time, as the guide does
  kubectl apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: $1
  namespace: velero
spec:
  includedNamespaces: [demo]
  defaultVolumesToFsBackup: $2
EOF
  until_true 600 bash -c "case \$(kubectl -n velero get backup $1 -o jsonpath='{.status.phase}') in Completed|Failed|PartiallyFailed|FailedValidation) true;; *) false;; esac"
  kubectl -n velero get backup "$1" -o jsonpath='{.status.phase}'
}
restore() {  # restore <restore-name> <backup-name>
  kubectl apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: $1
  namespace: velero
spec:
  backupName: $2
EOF
  until_true 600 bash -c "case \$(kubectl -n velero get restore $1 -o jsonpath='{.status.phase}') in Completed|Failed|PartiallyFailed|FailedValidation) true;; *) false;; esac"
  until_true 300 bash -c "! kubectl -n velero get podvolumerestores -l velero.io/restore-name=$1 -o jsonpath='{.items[*].status.phase}' | grep -qvE '^(Completed ?)*$'"
  kubectl -n demo wait --for=condition=Ready pod/backend-0 --timeout=300s >/dev/null 2>&1
  kubectl -n velero get restore "$1" -o jsonpath='{.status.phase}'
}
marker() { code "https://demo.platform.test:8443/store/$hash" >/dev/null; cat "$WORK/body"; }
good="hands-on-good-$RUN" bad="hands-on-bad-$RUN"
[ "$(backup "$good" true)" = Completed ] && pass "the backup that copies volumes Completed" || fail "the good backup did not complete"
[ "$(backup "$bad" false)" = Completed ] && pass "the backup that does not copy volumes Completed too" || fail "the bad backup did not complete"
n_good="$(kubectl -n velero get podvolumebackups -l velero.io/backup-name="$good" -o name | wc -l | tr -d ' ')"
n_bad="$(kubectl -n velero get podvolumebackups -l velero.io/backup-name="$bad" -o name | wc -l | tr -d ' ')"
[ "$n_good" -gt 0 ] && [ "$n_bad" -eq 0 ] && pass "podvolumebackups show the difference: $n_good against $n_bad" \
  || fail "podvolumebackups do not show the difference ($n_good against $n_bad)"
autosync demo off
kubectl delete namespace demo --wait=true --timeout=300s >/dev/null
[ "$(restore "from-bad-$RUN" "$bad")" = Completed ] && pass "the restore from the bad backup says Completed" || fail "the bad restore did not complete"
got="$(marker)"
[ "$got" != "written before the incident" ] && pass "and the data is gone" || fail "the data survived a backup that did not copy it"
kubectl delete namespace demo --wait=true --timeout=300s >/dev/null
[ "$(restore "from-good-$RUN" "$good")" = Completed ] && pass "the restore from the good backup Completed" || fail "the good restore did not complete"
got="$(marker)"
[ "$got" = "written before the incident" ] && pass "and the marker is back" || fail "the good restore did not bring the marker back: '${got:0:200}'"
autosync demo on
EXPECTED_APPS=demo "$ROOT/scripts/wait-for-platform.sh" 300 >/dev/null && pass "Argo CD finds the demo identical to Git" \
  || fail "the demo is not Synced and Healthy after the exercise"

printf '\n'
printf '%s\n' "${results[@]}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### hands-on guide"; echo; echo '```'; printf '%s\n' "${results[@]}"; echo '```'; } >>"$GITHUB_STEP_SUMMARY"
fi
exit "$failed"
