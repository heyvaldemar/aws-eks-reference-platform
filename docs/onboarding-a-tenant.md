# Onboarding a tenant

A tenant is a team with a namespace on the platform. Onboarding one is a pull request that adds one directory; nothing in the platform's own files changes, and the team inherits every guardrail the moment its namespace exists.

## What the team gets

| | |
|---|---|
| A namespace, named after the team | Pod Security `restricted`, enforced by the API server |
| `https://<team>.<domain>` | on the platform Gateway, with the platform's certificate |
| Admission policies | images by digest, requests and a memory limit, readiness and liveness probes; enforced natively, so they hold while Kyverno is down |
| Network isolation | a default-deny NetworkPolicy, generated and kept in place by Kyverno; the team opens only the paths it needs |
| Metrics | a ServiceMonitor in the namespace is scraped by the platform's Prometheus, once a NetworkPolicy lets the monitoring namespace in (as `apps/demo` does) |
| Backups | Velero backs up the namespace when it is added to the schedule (`platform/values/velero/common.yaml`) |

What it cannot do: tenants run under their own Argo CD project (`tenants` in `platform/appsets/project.yaml`), which allows no cluster-scoped kind but the team's Namespace, no platform namespace as a destination, and no ResourceQuota, LimitRange or Kyverno PolicyException. A ClusterRoleBinding or a policy exception in `apps/<team>/` is refused by Argo CD before the API server sees it.

What it does not get by default: the platform's secret store. `ClusterSecretStore/platform` lists the namespaces allowed to read through it, and that list is in a platform file (`manifests/*/secret-store.yaml`), so a team cannot grant itself access by editing its own manifests. A team that needs secrets gets its own store, scoped to its own prefix and, on EKS, its own IAM role; that is a platform change, reviewed as one.

## The steps

1. Copy the template, named after the team. The name is a DNS label: lowercase letters, digits and hyphens.

   ```bash
   cp -R apps/_template apps/payments
   rm apps/payments/README.md
   grep -rl TEAM apps/payments | xargs sed -i.bak 's/TEAM/payments/g' && find apps/payments -name '*.bak' -delete
   ```

2. Replace the example service in `apps/payments/base/app.yaml` with the team's: its image **by digest** (`docker buildx imagetools inspect <image>:<tag>` prints it), its port, its probes, its requests and limits. Keep the security context; Pod Security restricted refuses anything looser.

3. Open the network paths the service needs in `network-policies.yaml`, one NetworkPolicy per path, and nothing else.

4. Check it locally before anyone reviews it:

   ```bash
   make check
   ```

   The render includes the new tenant; kubeconform, kube-linter and the policy tests run against it. A missing digest or probe fails here, not at admission.

5. Open the pull request. CI runs the same checks and the kind e2e suite. After it merges and a cluster moves to the new revision, Argo CD creates the `payments` Application and the namespace, and `https://payments.<domain>` answers.

## Proof that it works

`apps/team-b` was made exactly this way, and the kind e2e suite checks it on every change: its route answers, it has its own default-deny, and an ExternalSecret in its namespace that tries to read the demo tenant's secret through the platform store is refused while the demo's own one syncs.

## Removing a tenant

Delete `apps/<team>/` in a pull request. When the cluster moves to that revision the ApplicationSet deletes the Application. The namespace and its data are deleted with it only if the Application carries Argo CD's resources finalizer; this platform does not add it, on purpose, so removing a directory never deletes a team's data by accident. Delete the namespace by hand once its backups are no longer needed.
