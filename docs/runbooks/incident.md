# Incident

First minutes. The goal is to know what changed and what is broken before changing anything.

## 0. If a page brought you here

`DemoErrorBudgetBurnFast` (severity `page`) means more than 7.2% of a service's requests failed over the last hour and the last five minutes: at that rate the month's error budget is gone in about two days. The SLO and its alerts are in `apps/demo/base/slo.yaml`; the dashboard is "Demo service level objectives" in Grafana (`kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80`). Read which service, then go on below.

## 1. What does the platform say about itself

```bash
./scripts/diagnose.sh
```

Applications that are not Synced and Healthy and why, pods that are not running, the last warning events, the previous logs of anything that restarted, and Velero's state. It only reads.

## 2. What changed

```bash
# the revision the cluster runs, and when it moved
kubectl -n argocd get secret in-cluster -o jsonpath='{.metadata.annotations.platform_revision}'; echo
kubectl -n argocd get application -o custom-columns=NAME:.metadata.name,REVISION:.status.sync.revision,DEPLOYED:.status.operationState.finishedAt
git log --oneline <that revision> -10
```

If the break lines up with a revision change, roll back first and investigate after ([rollback.md](rollback.md)).

## 3. Is traffic getting in

```bash
make tunnel   # kind; on EKS the hostname resolves to the load balancer
curl -sv --cacert platform-ca.crt --resolve demo.platform.test:8443:127.0.0.1 https://demo.platform.test:8443/ -o /dev/null
kubectl -n gateway get gateway platform -o jsonpath='{.status.conditions}'; echo
kubectl -n demo get httproute demo -o jsonpath='{.status.parents[0].conditions}'; echo
```

A route that is `Accepted` but returns 503 means Envoy has no healthy endpoint: check the pods, then the NetworkPolicies (a deny looks exactly like a dead backend from outside).

## 4. Is admission refusing something

```bash
kubectl get events -A --field-selector reason=FailedCreate | tail -20
kubectl get policyreports -A
```

A Kyverno refusal names its policy in the message. Do not delete the policy to get a deploy through; fix the workload, or add a PolicyException in Git with a reason and an end date.

## 5. Write it down

Time of detection, what was seen, what was changed and when, and what fixed it. Every incident that found a gap ends with a check that would have caught it, and the check is proven against a planted violation before it is trusted.
