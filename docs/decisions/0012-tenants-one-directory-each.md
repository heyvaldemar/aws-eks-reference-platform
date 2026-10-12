# 12. Tenants: one directory each, under a restricted project

- Status: proposed
- Date: 2026-10-12

## Context

A platform exists for the teams that use it. Onboarding a team should be a change the team can make and the platform can review in minutes, and it should be impossible for that change to reach beyond the team's own namespace.

## Decision

- **One directory per tenant.** An ApplicationSet (`platform/appsets/tenants.yaml`) uses a matrix of the cluster generator and a Git directory generator over `apps/*`, read at the cluster's pinned revision. A team is onboarded by a pull request that copies `apps/_template` to `apps/<team>/`; no platform file changes. The team gets `<team>.<domain>` on the shared Gateway.
- **A restricted AppProject.** Tenant Applications belong to `tenants`, not to `platform`. It allows manifests from this repository only, no cluster-scoped kind but the team's Namespace, no platform namespace as a destination, and no ResourceQuota, LimitRange or Kyverno PolicyException.
- **Guardrails by namespace label.** The tenant label on the namespace is what admission policies, the generated default-deny NetworkPolicy and the Gateway's route admission key on; Pod Security restricted is mandatory for it.
- **Secrets are not shared by default.** The platform's ClusterSecretStore lists the namespaces that may use it, in a file the platform owns. A tenant that needs secrets gets its own store and, on EKS, its own IAM role scoped to its prefix.
- `apps/team-b` is made from the template and kept as the proof: the e2e suite checks its route, its default-deny, that it cannot read the demo tenant's secret, and that an Application of its project aimed at `kube-system` is refused.

## Consequences

- Self-service onboarding with review: the diff is one directory, and everything that could make it dangerous is refused by the project or by admission, not by a reviewer's attention.
- Tenants share a cluster, a Gateway and a Prometheus. Noisy-neighbour limits (a ResourceQuota per tenant namespace) are the next step; the project already prevents a tenant from writing its own.
- Per-tenant secret stores on EKS need a Pod Identity role per tenant, which is a Terraform change per team. That is deliberate friction for the one thing a mistake cannot take back.
- Removing a directory deletes the Application but not the namespace: the template carries no resources finalizer, so data is never deleted by a merge.

## Alternatives

- **One ApplicationSet per tenant, written by the platform team.** Every onboarding becomes a platform change; the platform team becomes the queue.
- **Namespace-as-a-service tools (Capsule, Kiosk, hierarchical namespaces).** More capable multi-tenancy, one more controller to run; worth it at dozens of teams, not to prove the model.
- **A cluster per tenant.** The strongest isolation and the highest cost; the right answer for regulated or hostile tenants, not for teams of one organization.

## How to explain this to a customer

A team gets its own space on the platform by adding one folder in a pull request: its own address, its own network isolation, and the same security rules as everyone else, without waiting for the platform team to build anything. What a team can put in that folder is limited by the platform: it cannot give itself cluster-wide rights, reach into another team's space, switch off the rules, or read another team's secrets. Those limits are tested every day by trying to break them.
