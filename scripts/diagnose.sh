#!/usr/bin/env bash
# diagnose.sh - print what a failed run needs to be understood without the
# cluster: Applications and their conditions, pods that are not running,
# recent warning events, and the logs of anything crash-looping. Read-only.
set -uo pipefail
section() { printf '\n===== %s\n' "$*"; }

section "Argo CD Applications"
kubectl -n argocd get applications.argoproj.io \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision
kubectl -n argocd get applications.argoproj.io -o json | python3 -c '
import json, sys
for a in json.load(sys.stdin)["items"]:
    st = a.get("status", {})
    # Orphaned-resource warnings are information, not a failure.
    msgs = [c.get("message", "") for c in st.get("conditions", []) if c.get("type") != "OrphanedResourceWarning"]
    op = st.get("operationState", {})
    if op.get("phase") not in (None, "Succeeded"):
        msgs.append("sync %s: %s" % (op.get("phase"), op.get("message", "")))
    bad = [r for r in st.get("resources", [])
           if r.get("status") == "OutOfSync" or r.get("health", {}).get("status") in ("Degraded", "Missing", "Progressing", "Suspended")]
    for r in bad[:10]:
        msgs.append("%s %s/%s: %s %s %s" % (r.get("kind"), r.get("namespace", ""), r.get("name"), r.get("status"),
                    r.get("health", {}).get("status", ""), r.get("health", {}).get("message", "")))
    if msgs:
        print("--", a["metadata"]["name"])
        for m in msgs:
            print("   ", m[:400])
'

# A sync that waits names the object, "waiting for healthy state of
# monitoring.coreos.com/Prometheus/x", and nothing else: Argo CD 3 keeps no
# per-resource health in the Application, so the loop above cannot show why.
# The object's own status can.
section "What the waiting syncs wait on"
kubectl -n argocd get applications.argoproj.io -o json | python3 -c '
import json, re, sys
seen = set()
for a in json.load(sys.stdin)["items"]:
    msg = a.get("status", {}).get("operationState", {}).get("message", "")
    for group, kind, name in re.findall(r"healthy state of ([^/\s]*)/([^/\s]+)/([^\s,]+)", msg):
        if (group, kind, name) not in seen:
            seen.add((group, kind, name))
            print("%s.%s" % (kind, group) if group else kind, name)
' | while read -r resource name; do
  kubectl get "$resource" -A --field-selector "metadata.name=$name" -o json 2>&1 | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    items = json.loads(raw)["items"]
except ValueError:
    print("---", sys.argv[1], sys.argv[2], "(not readable)"); print("   ", raw.strip()[:400]); sys.exit()
if not items:
    print("---", sys.argv[1], sys.argv[2], "not found")
for o in items:
    print("---", sys.argv[1], "%s/%s" % (o["metadata"].get("namespace", ""), o["metadata"]["name"]))
    st = o.get("status", {})
    for c in st.get("conditions", []):
        print("    %s=%s %s: %s" % (c.get("type"), c.get("status"), c.get("reason", ""), c.get("message", "")[:300]))
    rest = {k: v for k, v in st.items() if k != "conditions" and not isinstance(v, (dict, list))}
    if rest:
        print("   ", rest)
' "$resource" "$name"
done

section "Pods not Running or not Ready"
kubectl get pods -A --no-headers | awk '$4 != "Running" && $4 != "Completed" || $3 ~ /^0\//'

section "Warning events, last 40"
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -40

section "Logs of restarting containers"
kubectl get pods -A -o json | python3 -c '
import json, sys
for p in json.load(sys.stdin)["items"]:
    for c in p.get("status", {}).get("containerStatuses", []):
        if c.get("restartCount", 0) > 0:
            print(p["metadata"]["namespace"], p["metadata"]["name"], c["name"])
' | while read -r ns pod container; do
  echo "--- $ns/$pod $container (previous run)"
  kubectl -n "$ns" logs "$pod" -c "$container" --previous --tail=40 2>&1
done

section "Velero"
kubectl -n velero get backupstoragelocations 2>/dev/null
kubectl -n velero get backups.velero.io,restores.velero.io \
  -o custom-columns='KIND:.kind,NAME:.metadata.name,PHASE:.status.phase,ERRORS:.status.errors,WARNINGS:.status.warnings,WHY:.status.failureReason,INVALID:.status.validationErrors' 2>/dev/null
kubectl -n velero get podvolumebackups.velero.io,podvolumerestores.velero.io \
  -o custom-columns='KIND:.kind,NAME:.metadata.name,POD:.spec.pod.name,VOLUME:.spec.volume,PHASE:.status.phase,MESSAGE:.status.message' 2>/dev/null
