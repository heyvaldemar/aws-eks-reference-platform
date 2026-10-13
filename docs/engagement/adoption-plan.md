# Adoption plan

Twelve to sixteen weeks from discovery to the last wave, in five phases. A phase ends when its exit criteria pass on the customer's cluster, not on a date. The weeks are the plan. The checks are the gate.

## Phases

| Phase | Weeks | What happens | Exit criteria |
|---|---|---|---|
| 0. Discovery and prerequisites | 1–2 | [Discovery](discovery.md) answered; AWS account, domain, identity provider and cost ceiling decided; the service inventory sorted into waves | the success plan's "agreed during discovery" table filled in and signed |
| 1. Foundation | 3–4 | `make eks-plan`, then `make eks-up` in a non-production account under the guards of [ADR 10](../decisions/0010-aws-validation-runs.md); the platform installed by Argo CD; the e2e suite run against it; a week of measured cost | success plan rows 1–4, 6–11 pass on EKS; measured cost within the ceiling |
| 2. Pilot | 5–7 | one team moves two or three stateless services, using [onboarding a tenant](../onboarding-a-tenant.md) and nothing else | row 5 passes; the pilot team deploys a change without help; the time that took is recorded |
| 3. Waves | 8–13 | the remaining services in waves of eight to ten, stateless first, data-heavy last; supply chain admission switched on before the first wave | each wave's services serve production traffic for two weeks with the Compose stack still warm |
| 4. Production and handover | 14–16 | the production account built the same way; the restore drill timed against the agreed RTO; the [handover](handover.md) | row 7 within RTO on production; the owning team runs one upgrade and one restore alone |

## From a Compose stack to a tenant

Every service moves the same way, because a Compose file and this platform describe the same things in different places. The table is the conversion. Learn it once.

| In the Compose stack | On the platform | Why it changes |
|---|---|---|
| `image: name:tag` | `image: name@sha256:…` in `apps/<team>/base/app.yaml` | admission refuses a tag (e2e 1, 4) |
| `deploy.resources.limits` | `resources.requests` and a memory limit | admission requires both; the namespace quota counts requests |
| `healthcheck:` | readiness and liveness probes | admission requires them; Argo CD's health is built on them |
| Traefik labels, a published port | an HTTPRoute on the platform Gateway | one Gateway, one certificate, no LoadBalancer or NodePort per team |
| `networks:` | NetworkPolicies, one per allowed path | the namespace starts at default deny |
| `.env` with secrets | an ExternalSecret from the platform's secret store | secrets live in AWS Secrets Manager, not in a file on a VM |
| a named volume | a PersistentVolumeClaim | Velero backs it up once the namespace is in the schedule |
| a `backups` sidecar dumping a database | Velero for the volume; a CronJob for a database-native dump where the RPO needs one | a file-system copy of a running database is not a consistent backup |
| `depends_on` | readiness probes, and an init container where order matters | Kubernetes starts everything at once and retries |

The deployment templates in [heyvaldemar's catalog](https://github.com/heyvaldemar/catalog) all have the Compose shape on the left, with a backup service and a restore script beside each stack; they are a ready set of worked examples for a conversion workshop.

## Rollback during the waves

Until a wave's two weeks are over, its Compose stack keeps running with its data synchronized. DNS is the switch. A wave that fails its exit criteria moves back by changing the record, and nothing is deleted on the VMs until the wave is signed off. Rolling the platform itself back is [one Git revert](../runbooks/rollback.md); what a rollback cannot undo is listed there.

## What could move the dates

- A service with no owner. Discovery finds it, and the waves wait until it has one or is retired.
- A database that turns out to belong in RDS. That is a separate migration with its own window, and the service moves after it.
- Images without an arm64 build. They run on amd64 nodes, which Karpenter allows, at a higher price ([sizing](sizing.md)).
