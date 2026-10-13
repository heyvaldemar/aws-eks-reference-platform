# Discovery

Questions to answer before anything is built. Each one names what its answer changes, so an answer that changes nothing is a question to drop.

## Outcomes

| Question | What the answer changes |
|---|---|
| Which two outcomes would make the sponsor call this a success in six months? | The first rows of the [success plan](success-plan.md); everything else is secondary |
| Which audit or compliance questions are open today, and who asks them? | Which evidence the success plan records (image provenance, restore time, admission logs) |
| What is the monthly cost ceiling for the platform, before workloads? | `nat_gateway_count`, node sizes, log retention ([ADR 11](../decisions/0011-cost-defaults.md)) |

## Workloads

| Question | What the answer changes |
|---|---|
| List every service: image, ports, volumes, environment, who owns it. A `docker compose config` per stack is enough. | The wave plan; services without an owner are found here, not in production |
| Which services keep data, and where: a volume, a database container, an external database? | Whether a service moves in a wave or last, and whether its database belongs in RDS rather than in the cluster |
| Which images are built in-house, and is each available for arm64? | Karpenter's architecture order (Graviton first) and which services pin amd64 |
| Which services need inbound traffic from outside, and on which hostnames? | HTTPRoutes on the platform Gateway, DNS records, certificates |
| Which talk to each other, and to what outside the cluster? | The NetworkPolicies each tenant opens; everything else stays denied |

## Teams and tenancy

| Question | What the answer changes |
|---|---|
| Which teams will deploy, and is a team the right unit for a namespace? | One directory under `apps/` per tenant ([ADR 12](../decisions/0012-tenants-one-directory-each.md)) |
| What does the largest team run at peak, in CPU and memory? | The default tenant quota (`platform/tenant/values.yaml`) and the exceptions |
| Who may approve a change to a team's directory, and to the platform's files? | CODEOWNERS; write access to `platform/` is the platform's real control boundary |

## Identity and access

| Question | What the answer changes |
|---|---|
| Which identity provider do engineers sign in with? | SSO for Argo CD and Grafana, which the platform does not have yet |
| Who needs `kubectl` access to the cluster, and with which rights? | EKS access entries and their policies ([ADR 3](../decisions/0003-pod-identity-and-access-entries.md)) |
| Which services call AWS APIs, and which? | Pod Identity associations, one role per service account |

## Security

| Question | What the answer changes |
|---|---|
| Must every image be signed and scanned before it runs? | Whether phase 3 adds the supply chain admission policies, and which signer they accept |
| Which images come from third parties, and from which registries? | The registry allowlist and the pull-through cache, if any |
| Is runtime detection required (Falco, Tetragon), and who would read its alerts? | A platform add-on and an on-call path; without a reader it is noise |
| Does traffic inside the cluster have to be encrypted? | A service mesh or the VPC CNI's encryption; today traffic ends TLS at the Gateway |

## Data, backup and recovery

| Question | What the answer changes |
|---|---|
| Per service tier: how much data may be lost (RPO), how long may it be down (RTO)? | Velero's schedule, the restore drill's pass mark, and which services need a database-native backup as well |
| Has any backup been restored in the last year? By whom, how long did it take? | The baseline the success plan improves on |

## Operations

| Question | What the answer changes |
|---|---|
| Who is on call today, for what, and with which tool? | Where the SLO pages go ([ADR 13](../decisions/0013-slos-proven-to-page.md)) |
| Which changes need a change window, and who approves it? | Argo CD sync windows and the upgrade runbook's schedule |
| Who will own the platform after the engagement, and how many people is that? | The [handover](handover.md), and whether the day-2 routine fits the team |
