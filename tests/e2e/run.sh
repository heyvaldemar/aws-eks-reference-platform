#!/usr/bin/env bash
# tests/e2e/run.sh - prove the running platform does what the README says.
#
# Runs against the cluster in the current kubeconfig, after
# scripts/wait-for-platform.sh has seen every Application Synced and Healthy.
# Each check states what it proves; together they are the claim "tested daily
# on kind". Every refusal is paired with a control that must be accepted, so
# a check cannot pass because something refuses everything.
#
#   1. every running image is pinned by digest
#   2. namespaces enforce the Pod Security level they declare
#   3. the Gateway serves demo.<domain> over HTTPS with the platform CA's
#      certificate, redirects HTTP, and shows a value from the secret store
#   4. admission refuses each planted violation in tests/e2e/plants and
#      admits the compliant control, and keeps refusing them with Kyverno's
#      admission controller scaled to zero (the policies are compiled into
#      native ValidatingAdmissionPolicies); Argo CD then brings Kyverno back
#   5. connections the network policies do not allow are refused
#   6. metrics are scraped and traces arrive as span metrics; the demo's SLO
#      rules are loaded, its dashboard is in Grafana, and when the frontend
#      fails the fast-burn alert really fires
#   7. Velero backs up the demo tenant, the namespace is deleted, and the
#      restore brings back the marker written before the backup
#
# Needs kubectl, curl and python3. Writes a summary to $GITHUB_STEP_SUMMARY
# when it is set.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DOMAIN="${DOMAIN:-platform.test}"
HOST="demo.$DOMAIN"
HTTPS_PORT=28443 HTTP_PORT=28080
WORK="$(mktemp -d)"
PF_PID=""
results=()
failed=0

# shellcheck disable=SC2329  # called by the EXIT trap
cleanup() {
  # Never leave Kyverno with auto-sync off, whatever failed.
  kubectl -n argocd patch application kyverno --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null 2>&1
  [ -n "$PF_PID" ] && { kill "$PF_PID"; wait "$PF_PID"; } 2>/dev/null
  kubectl delete namespace e2e-probe --ignore-not-found --wait=false >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { results+=("PASS  $1"); printf '  ok    %s\n' "$1"; }
fail() { results+=("FAIL  $1"); printf '  FAIL  %s\n' "$1"; failed=1; }
step() { printf '\n== %s\n' "$*"; }

# curl through a port-forward to the Envoy proxy, with the name resolving to it
# and the platform CA as the only trusted root.
gw() { curl -sS --max-time 10 --resolve "$HOST:$HTTPS_PORT:127.0.0.1" --cacert "$WORK/ca.crt" "$@"; }

start_port_forward() {
  local svc
  svc="$(kubectl -n envoy-gateway-system get svc \
    -l gateway.envoyproxy.io/owning-gateway-name=platform,gateway.envoyproxy.io/owning-gateway-namespace=gateway \
    -o jsonpath='{.items[0].metadata.name}')"
  [ -n "$svc" ] || return 1
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
  kubectl -n envoy-gateway-system port-forward "svc/$svc" "$HTTPS_PORT:443" "$HTTP_PORT:80" >"$WORK/pf.log" 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 30); do
    (exec 3<>"/dev/tcp/127.0.0.1/$HTTPS_PORT") 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

prom() {  # prom <PromQL> -> the first sample's value, or empty
  local q
  q="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1], safe=""))' "$1")"
  kubectl get --raw "/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$q" 2>/dev/null |
    python3 -c 'import json,sys
r=json.load(sys.stdin)["data"]["result"]
print(r[0]["value"][1] if r else "")' 2>/dev/null
}

# --- 1 -----------------------------------------------------------------------
step "1. every running image is pinned by digest"
# kube-system and local-path-storage come with the kind node image, which is
# itself pinned by digest in kind/cluster.yaml.
unpinned="$(kubectl get pods -A -o json | python3 -c '
import json,sys
skip={"kube-system","local-path-storage"}
for p in json.load(sys.stdin)["items"]:
    ns=p["metadata"]["namespace"]
    if ns in skip: continue
    for c in p["spec"].get("initContainers",[])+p["spec"]["containers"]:
        if "@sha256:" not in c["image"]: print(ns, p["metadata"]["name"], c["image"])')"
if [ -z "$unpinned" ]; then pass "running images: all pinned by digest"; else fail "running images without a digest:"$'\n'"$unpinned"; fi

# --- 2 -----------------------------------------------------------------------
step "2. Pod Security levels"
for pair in demo=restricted gateway=restricted argocd=restricted monitoring=restricted \
            kyverno=restricted cert-manager=restricted external-secrets=restricted \
            envoy-gateway-system=restricted object-store=restricted velero=privileged; do
  ns="${pair%%=*}" want="${pair#*=}"
  got="$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)"
  if [ "$got" = "$want" ]; then pass "namespace $ns enforces $want"; else fail "namespace $ns enforces '${got:-nothing}', expected $want"; fi
done

# --- 3 -----------------------------------------------------------------------
step "3. the Gateway, its certificate and the secret store"
kubectl -n cert-manager get secret platform-ca -o jsonpath='{.data.ca\.crt}' | base64 -d >"$WORK/ca.crt"
if ! start_port_forward; then
  fail "could not port-forward to the Envoy proxy"
else
  body="$(gw "https://$HOST:$HTTPS_PORT/" 2>"$WORK/curl.err")"
  if [ -n "$body" ]; then
    pass "https://$HOST answers, with a certificate the platform CA signed"
  else
    fail "https://$HOST did not answer: $(cat "$WORK/curl.err")"
  fi
  want="$(kubectl -n demo get secret demo-message -o jsonpath='{.data.message}' | base64 -d)"
  got="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("message",""))' "$body" 2>/dev/null)"
  if [ -n "$want" ] && [ "$got" = "$want" ]; then
    pass "the frontend shows the message External Secrets synced from the store"
  else
    fail "the frontend's message is '$got', the store holds '$want'"
  fi
  code="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 10 \
    --resolve "$HOST:$HTTP_PORT:127.0.0.1" "http://$HOST:$HTTP_PORT/")"
  case "$code" in
    "301 https://$HOST"*) pass "plain HTTP answers with a redirect to HTTPS" ;;
    *) fail "plain HTTP answered '$code', expected a 301 to https://$HOST" ;;
  esac
fi

# --- 4 -----------------------------------------------------------------------
step "4. admission: each planted violation is refused, the control is admitted"
plants() {  # plants <label>: every plant refused as expected, the control admitted
  local plant name expect out rc
  for plant in "$HERE"/plants/*.yaml; do
    name="$(basename "$plant" .yaml)"
    expect="$(sed -n 's/^# expect: //p' "$plant")"
    out="$(kubectl apply --dry-run=server -f "$plant" 2>&1)"
    rc=$?
    if [ "$expect" = admitted ]; then
      if [ $rc -eq 0 ]; then pass "$1$name: admitted"; else fail "$1$name was refused: $out"; fi
    elif [ $rc -ne 0 ] && grep -q "$expect" <<<"$out"; then
      pass "$1$name: refused by $expect"
    else
      fail "$1$name: expected a refusal by '$expect', got (rc=$rc): $out"
    fi
  done
}

plants ""

step "4b. the same refusals with Kyverno's admission controller stopped"
for vp in $(kubectl get validatingpolicies.policies.kyverno.io -o jsonpath='{.items[*].metadata.name}'); do
  if kubectl get validatingadmissionpolicy "vpol-$vp" >/dev/null 2>&1; then
    pass "$vp is compiled into a ValidatingAdmissionPolicy the API server enforces"
  else
    fail "$vp has no ValidatingAdmissionPolicy; only a Kyverno webhook enforces it"
  fi
done
kubectl -n argocd patch application kyverno --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
kubectl -n kyverno scale deployment kyverno-admission-controller --replicas=0 >/dev/null
kubectl -n kyverno wait --for=delete pod -l app.kubernetes.io/component=admission-controller --timeout=180s >/dev/null 2>&1
if kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg >/dev/null 2>&1; then
  echo "  (Kyverno's resource webhook is still registered)"
else
  echo "  (Kyverno removed its resource webhook when it stopped)"
fi
plants "Kyverno down: "
kubectl -n argocd patch application kyverno --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null
back=""
for _ in $(seq 1 60); do
  back="$(kubectl -n kyverno get deployment kyverno-admission-controller -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
  [ "${back:-0}" -ge 1 ] && break
  sleep 5
done
if [ "${back:-0}" -ge 1 ]; then pass "Argo CD brought Kyverno's admission controller back from zero"; else
  fail "Kyverno's admission controller is still at zero after auto-sync was turned back on"
fi
for _ in $(seq 1 30); do
  kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg >/dev/null 2>&1 && break
  sleep 5
done

# --- 5 -----------------------------------------------------------------------
step "5. network policies: what is not allowed is refused"
kubectl apply -f "$HERE/probe.yaml" >/dev/null
kubectl -n e2e-probe wait pod/probe --for=condition=Ready --timeout=120s >/dev/null
try() {  # try <namespace> <workload> <url>: exit 0 when the call succeeds
  kubectl -n "$1" exec "$2" -- podcli check http "$3" --timeout=3s --retry=0 >/dev/null 2>&1
}
if try e2e-probe probe "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/-/ready"; then
  pass "control: the probe pod can make HTTP calls to a namespace without policies"
  if try e2e-probe probe "http://backend.demo.svc.cluster.local:9898/healthz"; then
    fail "a pod in another namespace reached the demo backend"
  else
    pass "a pod in another namespace cannot reach the demo backend"
  fi
else
  fail "control: the probe pod cannot make any HTTP call, so the refusals below would prove nothing"
fi
if try demo deploy/frontend "http://backend.demo.svc.cluster.local:9898/healthz"; then
  fail "the frontend reached the backend, which no policy allows"
else
  pass "the frontend cannot reach the backend (no policy allows it)"
fi
if try demo statefulset/backend "https://github.com"; then
  fail "the backend reached the internet"
else
  pass "the backend cannot reach the internet"
fi

# --- 6 -----------------------------------------------------------------------
step "6. metrics and traces"
for _ in $(seq 1 20); do gw -o /dev/null "https://$HOST:$HTTPS_PORT/" 2>/dev/null; done
up=""
for _ in $(seq 1 12); do
  up="$(prom 'sum(up{namespace="demo"})')"
  [ "${up%.*}" = 3 ] && break
  sleep 10
done
if [ "${up%.*}" = 3 ]; then pass "Prometheus scrapes all three demo pods"; else fail "Prometheus sees ${up:-no} demo targets up, expected 3"; fi
calls=""
for _ in $(seq 1 12); do
  calls="$(prom 'sum(traces_spanmetrics_calls_total{service_name="frontend"})')"
  [ -n "$calls" ] && [ "${calls%.*}" -gt 0 ] 2>/dev/null && break
  sleep 10
done
if [ -n "$calls" ] && [ "${calls%.*}" -gt 0 ] 2>/dev/null; then
  pass "traces from the frontend reach the collector ($calls spans counted)"
else
  fail "no span metrics for the frontend: traces are not arriving"
fi

step "6b. the SLO: rules loaded, dashboard present, and the page fires on a failure"
promapi() { kubectl get --raw "/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-prometheus:9090/proxy/api/v1/$1" 2>/dev/null; }
bad_rules="$(promapi rules | python3 -c '
import json,sys
groups=[g for g in json.load(sys.stdin)["data"]["groups"] if g["name"].startswith("demo-slo")]
rules=[r for g in groups for r in g["rules"]]
print(len(rules), sum(1 for r in rules if r.get("health")!="ok"))' 2>/dev/null)"
if [ "${bad_rules:-0 0}" = "8 0" ]; then pass "Prometheus evaluates all 8 SLO rules without errors"; else
  fail "SLO rules loaded and failing (count, unhealthy): '${bad_rules:-none}'"; fi

kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 23000:80 >"$WORK/grafana-pf.log" 2>&1 &
GF_PID=$!
for _ in $(seq 1 30); do (exec 3<>/dev/tcp/127.0.0.1/23000) 2>/dev/null && break; sleep 1; done
found=""
for _ in $(seq 1 12); do
  # The password is read into curl's stdin config, never onto a command line.
  found="$(printf 'user = "admin:%s"\n' "$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)" |
    curl -s --max-time 10 --config - "http://127.0.0.1:23000/api/dashboards/uid/demo-slo" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["dashboard"]["title"])' 2>/dev/null)"
  [ -n "$found" ] && break
  sleep 10
done
{ kill "$GF_PID"; wait "$GF_PID"; } 2>/dev/null
if [ "$found" = "Demo service level objectives" ]; then pass "Grafana serves the SLO dashboard"; else
  fail "Grafana does not serve the demo-slo dashboard"; fi

# Make the frontend fail: podinfo answers /status/500 with a 500. Half a
# minute of steady errors on top of the light traffic so far is far beyond a
# 14.4x burn; the alert has `for: 2m`, so it should fire within about four.
firing() { promapi alerts | python3 -c '
import json,sys
a=[x for x in json.load(sys.stdin)["data"]["alerts"] if x["labels"].get("alertname")=="DemoErrorBudgetBurnFast" and x["labels"].get("job")=="frontend"]
print(a[0]["state"] if a else "none")' 2>/dev/null; }
( end=$(( $(date +%s) + 480 )); while [ "$(date +%s)" -lt "$end" ]; do
    gw -o /dev/null "https://$HOST:$HTTPS_PORT/status/500" 2>/dev/null; sleep 0.2
  done ) &
LOAD_PID=$!
state="none"
for _ in $(seq 1 48); do
  state="$(firing)"
  [ "$state" = firing ] && break
  sleep 10
done
{ kill "$LOAD_PID"; wait "$LOAD_PID"; } 2>/dev/null
if [ "$state" = firing ]; then pass "a failing frontend makes DemoErrorBudgetBurnFast fire"; else
  fail "the frontend failed for eight minutes and the fast-burn alert is '$state', not firing"; fi

# --- 7 -----------------------------------------------------------------------
step "7. backup, delete the tenant, restore"
marker="e2e-marker-$(date +%s)-$RANDOM"
hash="$(gw -X POST --data "$marker" "https://$HOST:$HTTPS_PORT/store" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hash"])' 2>/dev/null)"
if [ -z "$hash" ] || [ "$(gw "https://$HOST:$HTTPS_PORT/store/$hash")" != "$marker" ]; then
  fail "could not write the marker through the Gateway"
else
  pass "marker written to the backend's volume through the Gateway"
  name="e2e-$(date +%s)"
  # Argo CD would recreate the namespace the moment it is deleted; a restore
  # is done with the tenant's auto-sync off, as docs/runbooks/restore.md says.
  kubectl -n argocd patch application demo --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
  kubectl apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: $name
  namespace: velero
spec:
  includedNamespaces: [demo]
  defaultVolumesToFsBackup: true
  ttl: 2h0m0s
EOF
  phase=""
  for _ in $(seq 1 60); do
    phase="$(kubectl -n velero get backup "$name" -o jsonpath='{.status.phase}')"
    case "$phase" in Completed|Failed|PartiallyFailed|FailedValidation) break ;; esac
    sleep 5
  done
  volumes="$(kubectl -n velero get podvolumebackups -l velero.io/backup-name="$name" -o name | wc -l | tr -d ' ')"
  if [ "$phase" = Completed ] && [ "$volumes" -gt 0 ]; then
    pass "backup $name Completed with $volumes pod volume(s)"
    kubectl delete namespace demo --wait=true --timeout=5m >/dev/null
    if kubectl get namespace demo >/dev/null 2>&1; then
      fail "namespace demo is still there after delete"
    else
      pass "namespace demo deleted, volume and all"
      kubectl apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: $name
  namespace: velero
spec:
  backupName: $name
  includedNamespaces: [demo]
EOF
      phase=""
      for _ in $(seq 1 60); do
        phase="$(kubectl -n velero get restore "$name" -o jsonpath='{.status.phase}')"
        case "$phase" in Completed|Failed|PartiallyFailed|FailedValidation) break ;; esac
        sleep 5
      done
      if [ "$phase" = Completed ]; then pass "restore $name Completed"; else
        fail "restore $name ended $phase: $(kubectl -n velero get restore "$name" -o jsonpath='{.status}')"
      fi
      # The restore is Completed before the volume data is back: Velero's
      # node agent copies it into the new volume while the pod's restore
      # helper waits. Wait for every PodVolumeRestore, then for the pod.
      pvr=""
      for _ in $(seq 1 60); do
        pvr="$(kubectl -n velero get podvolumerestores -l velero.io/restore-name="$name" -o jsonpath='{.items[*].status.phase}')"
        [ -n "$pvr" ] && ! grep -qvE '^(Completed ?)+$' <<<"$pvr " && break
        sleep 5
      done
      echo "  pod volume restores: ${pvr:-none}"
      kubectl -n demo wait --for=condition=Ready pod/backend-0 --timeout=300s >/dev/null 2>&1
      kubectl -n demo rollout status deployment/frontend --timeout=300s >/dev/null 2>&1
      got="" code=""
      for _ in $(seq 1 24); do
        kill -0 "$PF_PID" 2>/dev/null || start_port_forward
        code="$(gw -o "$WORK/marker" -w '%{http_code}' "https://$HOST:$HTTPS_PORT/store/$hash" 2>"$WORK/curl.err")"
        got="$(cat "$WORK/marker" 2>/dev/null)"
        [ "$got" = "$marker" ] && break
        sleep 5
      done
      if [ "$got" = "$marker" ]; then
        pass "the marker written before the backup is served again after the restore"
      else
        fail "after the restore /store/$hash answered HTTP ${code:-none} '${got:0:200}' $(cat "$WORK/curl.err"), expected '$marker' (pod volume restores: ${pvr:-none})"
      fi
    fi
  else
    fail "backup $name ended '$phase' with $volumes pod volume(s)"
  fi
  kubectl -n argocd patch application demo --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null
  if EXPECTED_APPS=demo "$HERE/../../scripts/wait-for-platform.sh" 300 >/dev/null; then
    pass "Argo CD finds the restored tenant identical to Git"
  else
    fail "after the restore Argo CD does not report demo Synced and Healthy"
  fi
fi

# --- summary -------------------------------------------------------------------
printf '\n'
printf '%s\n' "${results[@]}"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### kind e2e"
    echo
    echo '```'
    printf '%s\n' "${results[@]}"
    echo '```'
  } >>"$GITHUB_STEP_SUMMARY"
fi
exit "$failed"
