# 12. Tenants: one directory each, one project each

- Status: proposed
- Date: 2026-10-12

## Context

A platform exists for the teams that use it. Onboarding a team should be a change the team can make and the platform can review in minutes, and it should be impossible for that change to reach beyond the team's own namespace.

The first version of this design failed that test twice before it shipped. All tenants shared one Argo CD project that allowed every namespace and then denied the platform's by pattern (`!kube-*`, `!argocd`, and so on). The kind e2e run aimed a tenant Application at `kube-system`, and Argo CD did not refuse it. A security review found the second gap: each tenant wrote its own Namespace, so a team could drop the tenant label that every admission policy keys on, set Pod Security to `privileged`, and run what it liked. A deny-list is a list of what someone remembered. The namespace's labels were the guardrail, and the team owned them.

## Decision

- **One directory per tenant.** Two ApplicationSets read the same matrix of the cluster generator and a Git directory generator over `apps/*`, at the cluster's pinned revision. A team is onboarded by a pull request that copies `apps/_template` to `apps/<team>/`; no platform file changes. The team gets `<team>.<domain>` on the shared Gateway.
- **The platform owns the namespace.** `tenant-guardrails.yaml` installs `platform/tenant`, a small chart in this repository, once per directory: the Namespace with the tenant label and Pod Security `restricted`, a ResourceQuota, and an AppProject named `tenant-<team>`. The team's directory holds only what runs inside the namespace.
- **One project per tenant, allow-list only.** `tenant-<team>` has one destination, the team's namespace. It takes manifests from the platform repository only, allows no cluster-scoped kind at all, and refuses a ResourceQuota, a LimitRange, a Kyverno PolicyException and a Gateway of the team's own. A manifest that names another namespace is refused by Argo CD before the API server sees it.
- **Platform names are reserved.** A directory becomes a namespace, a project and an Application name, so `apps/kyverno` or `apps/kube-system` would otherwise take a platform namespace. The chart refuses those names (`reserved` in its values, plus anything starting with `kube-` or `tenant-`), and its project is never created, so the team's Application is never created either. `scripts/check-argocd.py` fails when a platform namespace or Application is missing from that list, and runs the chart against every reserved name to prove it refuses.
- **A quota, and no LimitRange.** The quota counts CPU and memory requests, memory limits, pods, volumes and storage, and allows no LoadBalancer or NodePort Service. A LimitRange would fill in the requests and limits a team left out, and the admission policy that refuses a container without them would never see one.
- **Secrets are not shared by default.** The platform's ClusterSecretStore lists the namespaces that may use it, in a file the platform owns. A tenant that needs secrets gets its own store and, on EKS, its own IAM role scoped to its prefix.
- `apps/team-b` is made from the template and kept as the proof. The e2e suite checks its route and its default-deny, that it cannot read the demo tenant's secret, and that its project refuses an Application aimed at `kube-system` and its own manifests pointed at the `demo` namespace. It also checks that the namespace is tracked by `tenant-team-b`, not by the team.

## Consequences

- Self-service onboarding with review: the diff is one directory, and everything that could make it dangerous is refused by the project, the chart or admission, not by a reviewer's attention. Six planted violations in the static checks prove each refusal can fail.
- A tenant has two Applications. A restore pauses both (`docs/runbooks/restore.md`), or Argo CD recreates the namespace empty the moment it is deleted.
- The team's Application cannot sync before its project exists. On a new tenant the ApplicationSet retries it every few minutes; its first sync always lands in a namespace the platform has already labelled.
- The quota is one size for every tenant. A team that needs more is a platform change, reviewed as one; per-tenant sizes are a values file away when the second team asks.
- Per-tenant secret stores on EKS need a Pod Identity role per tenant, which is a Terraform change per team. That is deliberate friction for the one thing a mistake cannot take back.
- Removing a directory deletes both Applications but not the namespace: neither carries Argo CD's resources finalizer, so data is never deleted by a merge.

## Alternatives

- **One shared tenants project with platform namespaces denied.** Tried first; see Context. Every new platform namespace has to be remembered in the deny-list, and the CI run showed the deny patterns did not hold.
- **One ApplicationSet per tenant, written by the platform team.** Every onboarding becomes a platform change; the platform team becomes the queue.
- **Namespace-as-a-service tools (Capsule, Kiosk, hierarchical namespaces).** More capable multi-tenancy, one more controller to run; worth it at dozens of teams, not to prove the model.
- **A cluster per tenant.** The strongest isolation and the highest cost; the right answer for regulated or hostile tenants, not for teams of one organization.

## How to explain this to a customer

A team gets its own space on the platform by adding one folder in a pull request: its own address, its own network isolation, a fair share of the cluster, and the same security rules as everyone else, without waiting for the platform team to build anything. The platform, not the team, creates that space and decides what it may hold. A team cannot give itself cluster-wide rights, write into another team's space, switch off the rules, or take a name the platform uses. Those limits are tested every day by trying to break them, and the first version of this design is the reason: the daily test caught it letting a team out.
