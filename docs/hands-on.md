# Hands-on: break it, find it, fix it

Bring the kind version up, then break three things on purpose and repair each with `kubectl`. Each exercise is about 15 minutes. They map onto the CKA's largest domain, troubleshooting, plus networking and storage; nothing here needs a cloud account.

You need Docker with about 4 CPUs and 8 GB of memory for its VM, `make`, `git`, `curl` and Python 3 with PyYAML. `make` installs the pinned kind, kubectl and helm into `.cache/bin`.

## 0. Bring it up

```bash
git clone https://github.com/heyvaldemar/aws-eks-reference-platform.git
cd aws-eks-reference-platform
make up          # kind cluster, Argo CD, then everything else from Git: 6 to 10 minutes
export PATH="$PWD/.cache/bin:$PATH"
kubectl -n argocd get applications
```

Every Application should be `Synced` and `Healthy`. In a second terminal, keep the Gateway reachable for the whole session:

```bash
make tunnel
```

And check the demo answers:

```bash
curl -s --cacert platform-ca.crt --resolve demo.platform.test:8443:127.0.0.1 https://demo.platform.test:8443/ | head -5
```

One thing to know before breaking anything: Argo CD heals drift. Every `kubectl edit` below would be reverted within seconds, so each exercise first turns off auto-sync for the Application it touches. That switch is itself part of real incident work.

## 1. A policy change stops every deploy

**Warm up: the policies doing their job.** Try a pod whose image has a tag and no digest:

```bash
kubectl -n demo run tag-only --image=ghcr.io/stefanprodan/podinfo:6.15.0 --restart=Never
```

The refusal names a ValidatingAdmissionPolicy, `vpol-require-image-digest`. Kyverno compiled it from `policies/require-image-digest.yaml`, and the API server enforces it itself. Find the digest the running frontend uses and try again with it:

```bash
kubectl -n demo get deployment frontend -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

It is refused again, by something else this time. Keep reading the messages until the pod is admitted, or until you decide it should not be.

**Break it.** Someone tightens the probes policy without checking the workloads it covers. Be that someone:

```bash
kubectl -n argocd patch application policies --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl patch validatingpolicy require-probes --type json -p '[{"op":"replace","path":"/spec/validations/0/expression",
  "value":"object.spec.template.spec.containers.all(c, has(c.readinessProbe) && has(c.livenessProbe) && has(c.startupProbe))"}]'
```

**Find it.** Now any change to the demo is refused:

```bash
kubectl -n demo rollout restart deployment/frontend
```

The message says every container needs a readiness and a liveness probe. Check the deployment: it has both. A message that contradicts the object means the message is not the rule, so read the rule the API server is actually running, and compare it with Git:

```bash
kubectl get validatingadmissionpolicies
kubectl get validatingadmissionpolicy vpol-require-probes -o jsonpath='{.spec.validations[0].expression}'; echo
git show HEAD:policies/require-probes.yaml | grep -A1 'expression:'
kubectl -n argocd get application policies -o jsonpath='{.status.sync.status}'; echo
```

The live policy asks for a `startupProbe` that the file in Git does not, and Argo CD reports the policies Application `OutOfSync`.

**Fix it.** Git is the source of truth; let it win:

```bash
kubectl -n argocd patch application policies --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl get validatingadmissionpolicy vpol-require-probes -o jsonpath='{.spec.validations[0].expression}'; echo
kubectl -n demo rollout restart deployment/frontend
kubectl -n demo rollout status deployment/frontend
```

If the stricter rule was wanted, the fix is the other way round: add the probe to the workloads first, in Git, then tighten the policy.

**Going further: is admission still closed with Kyverno down?** Turn off auto-sync for the `kyverno` Application, scale `kyverno-admission-controller` to zero, and retry the tag-only pod. Kyverno removes its own webhooks when it stops, so a policy enforced only through them would let the pod in. These are enforced by the API server and still refuse. Turn auto-sync back on and watch Argo CD bring the replica back.

## 2. The site returns 503

**Break it.**

```bash
kubectl -n argocd patch application demo --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n demo patch networkpolicy allow-from-gateway --type json \
  -p '[{"op":"replace","path":"/spec/ingress/0/ports/0/port","value":9899}]'
```

**Find it.** From outside it looks like a dead backend:

```bash
curl -s -o /dev/null -w '%{http_code}\n' --cacert platform-ca.crt --resolve demo.platform.test:8443:127.0.0.1 https://demo.platform.test:8443/
```

Check the layers in order, from the edge inwards:

```bash
kubectl -n demo get httproute demo -o jsonpath='{.status.parents[0].conditions[*].type}'; echo   # Accepted, ResolvedRefs
kubectl -n demo get endpointslices                                                               # pods are there and ready
kubectl -n demo get pods                                                                         # and running
kubectl -n demo get networkpolicies
kubectl -n demo describe networkpolicy allow-from-gateway
```

The route is accepted and the endpoints are ready, so the requests are being dropped between Envoy and the pods. `default-deny` (generated by Kyverno for every tenant namespace) denies everything; `allow-from-gateway` is the only thing letting Envoy in, and it now names a port the pods do not listen on.

**Fix it.** Give the namespace back to Git:

```bash
kubectl -n argocd patch application demo --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

Then confirm the 200, and that the generated default-deny comes back if you delete it (`kubectl -n demo delete networkpolicy default-deny`, wait, list again).

## 3. A restore that said Completed

**Set it up.** Write something worth losing, then take two backups: one that copies volumes and one that does not.

```bash
HASH=$(curl -s --cacert platform-ca.crt --resolve demo.platform.test:8443:127.0.0.1 \
  -X POST --data "written before the incident" https://demo.platform.test:8443/store | python3 -c 'import json,sys; print(json.load(sys.stdin)["hash"])')
echo "$HASH"

for b in good:true bad:false; do
kubectl apply -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: hands-on-${b%%:*}
  namespace: velero
spec:
  includedNamespaces: [demo]
  defaultVolumesToFsBackup: ${b##*:}
EOF
done
kubectl -n velero get backups -w   # until both are Completed
```

**Break it.** Lose the namespace, and restore from the wrong backup.

```bash
kubectl -n argocd patch application demo --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl delete namespace demo --wait=true
kubectl apply -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: hands-on-from-bad
  namespace: velero
spec:
  backupName: hands-on-bad
EOF
kubectl -n velero get restore hands-on-from-bad -w   # Completed
kubectl -n demo rollout status statefulset/backend
curl -s --cacert platform-ca.crt --resolve demo.platform.test:8443:127.0.0.1 https://demo.platform.test:8443/store/$HASH
```

The restore is `Completed`, the pods are running, and the data is gone.

**Find it.** Ask what each backup actually copied:

```bash
kubectl -n velero get podvolumebackups -l velero.io/backup-name=hands-on-bad
kubectl -n velero get podvolumebackups -l velero.io/backup-name=hands-on-good
kubectl -n velero get backup hands-on-bad -o jsonpath='{.spec.defaultVolumesToFsBackup}'; echo
```

**Fix it.**

```bash
kubectl delete namespace demo --wait=true
kubectl apply -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: hands-on-from-good
  namespace: velero
spec:
  backupName: hands-on-good
EOF
kubectl -n velero get restore hands-on-from-good -w
kubectl -n demo rollout status statefulset/backend
curl -s --cacert platform-ca.crt --resolve demo.platform.test:8443:127.0.0.1 https://demo.platform.test:8443/store/$HASH
kubectl -n argocd patch application demo --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

The lesson the e2e run is built on: a restore is proven by reading the data back, never by its status.

## Clean up

```bash
make down
```

## What this covered

| Exercise | CKA area |
|---|---|
| 1. a policy change stops deploys | Troubleshooting: workloads that will not start; admission control |
| 2. 503 behind a Gateway | Services and networking: NetworkPolicy, endpoints, Gateway API |
| 3. a restore without data | Storage: volumes, claims, StatefulSets; backup and restore |

The CKA exam itself is plain Kubernetes, with no Argo CD, Kyverno or Velero. The `kubectl` habits are the ones it tests: read events, follow a request from the edge inwards, and check the data rather than the status.
