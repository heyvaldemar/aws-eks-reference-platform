# Onboarding a tenant

A tenant is a team with a namespace on the platform. Onboarding one is a pull request that adds one directory; nothing in the platform's own files changes, and the team inherits every guardrail the moment its namespace exists.

## What the team gets

| | |
|---|---|
| A namespace, named after the team | created and labelled by the platform; Pod Security `restricted`, enforced by the API server |
| A quota | 2 CPUs and 4 GiB of memory requested, 8 GiB of memory limits, 50 pods, 10 volumes and 50 GiB of storage; no LoadBalancer or NodePort Service (`platform/tenant/values.yaml`) |
| `https://<team>.<domain>` | on the platform Gateway, with the platform's certificate |
| Admission policies | images by digest, requests and a memory limit, readiness and liveness probes; enforced natively, so they hold while Kyverno is down |
| Network isolation | a default-deny NetworkPolicy, generated and kept in place by Kyverno; the team opens only the paths it needs |
| Metrics | a ServiceMonitor in the namespace is scraped by the platform's Prometheus, once a NetworkPolicy lets the monitoring namespace in (as `apps/demo` does) |
| Backups | Velero backs up the namespace when it is added to the schedule (`platform/values/velero/common.yaml`) |

What it cannot do: each tenant runs under an Argo CD project of its own, `tenant-<team>`, which the platform creates from `platform/tenant` alongside the namespace. Its only destination is the team's namespace; it allows no cluster-scoped kind at all, the Namespace included; and it allows only the namespaced kinds a service needs (`allowedKinds` in `platform/tenant/values.yaml`): workloads, Services, ConfigMaps, volumes, routes, network policies, ExternalSecrets and monitoring rules. Not on the list: Role and RoleBinding, Secret, SecretStore, ResourceQuota, LimitRange, Kyverno policies and exceptions, and Gateway. A manifest in `apps/<team>/` that names another namespace, binds the team admin of its own namespace, or writes a Namespace is refused by Argo CD before the API server sees it. A team that needs a kind not on the list asks for it in a platform change. The list is enforced twice: by the project, and by the account the team's syncs run as. Argo CD applies `apps/<team>/` as `tenant-<team>-deployer`, whose Role grants exactly those kinds in the team's namespace, so a sync that fails with `forbidden` names a kind the platform has not allowed. A directory cannot take a platform name either: `argocd`, `kyverno`, `kube-system` and the rest are reserved, and the platform refuses to create a tenant under one.

What it does not get by default: the platform's secret store. `ClusterSecretStore/platform` lists the namespaces allowed to read through it, and that list is in a platform file (`manifests/*/secret-store.yaml`), so a team cannot grant itself access by editing its own manifests. A team that needs secrets gets its own store, scoped to its own prefix and, on EKS, its own IAM role; that is a platform change, reviewed as one.

## The steps

1. Copy the template, named after the team. The name is a DNS label: lowercase letters, digits and hyphens, not starting with `kube-` or `tenant-`, and not one of the platform's own names (`reserved` in `platform/tenant/values.yaml`).

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

   The render includes the new tenant; kubeconform, kube-linter and the policy tests run against it, and the Argo CD check confirms that everything it renders stays in its own namespace. A missing digest or probe fails here, not at admission.

5. Open the pull request. CI runs the same checks and the kind e2e suite. After it merges and a cluster moves to the new revision, Argo CD creates `tenant-payments` (the namespace, its quota and its project) and then the team's `payments` Application, and `https://payments.<domain>` answers. The team's Application waits for its project: the ApplicationSet retries it every few minutes until the project exists.

## Proof that it works

`apps/team-b` was made exactly this way, and the kind e2e suite checks it on every change: its route answers, it has its own default-deny, an ExternalSecret in its namespace that tries to read the demo tenant's secret through the platform store is refused while the demo's own one syncs, and its project refuses an Application aimed at `kube-system`, its own manifests pointed at the `demo` namespace, and a RoleBinding that would make it admin of its namespace.

## Removing a tenant

Delete `apps/<team>/` in a pull request. When the cluster moves to that revision the ApplicationSets delete both Applications, `<team>` and `tenant-<team>`. The namespace and its data are deleted with them only if an Application carries Argo CD's resources finalizer; this platform does not add it, on purpose, so removing a directory never deletes a team's data by accident. Delete the namespace by hand once its backups are no longer needed.
