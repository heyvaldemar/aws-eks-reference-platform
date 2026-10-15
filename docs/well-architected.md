# Well-Architected review

The platform read against the six pillars of the AWS Well-Architected Framework: what it does, the evidence that it does it, and what it does not do yet. The evidence column points at a check, not at a description; where the only evidence is a Terraform test on a mocked plan, the row says so. The weekly EKS run on a real account (`tests/eks/run.sh`, passing since 2026-10-15) is evidence only for what it checks.

## Operational excellence

| Practice | Evidence |
|---|---|
| Everything is code, applied by Argo CD from one pinned commit per cluster | `check-argocd.py`: no source and no generator may follow a branch |
| A fresh cluster from nothing, every day | `kind-e2e.yml`: create, bootstrap, every Application `Synced` and `Healthy`, then every check |
| Runbooks for upgrade, rollback, restore and incident | `docs/runbooks/`; the restore runbook is the procedure the daily drill runs |
| Operators practise on the real platform | `docs/hands-on.md`, three break-and-fix exercises, run as written every week (`hands-on.yml`) |
| Drift from upstream is noticed | `check-freshness.py`: charts, images, tools, providers and the Kubernetes version, weekly |
| A failure says where to look | `scripts/diagnose.sh` runs when a CI job fails: Applications and their conditions, pods that are not running, recent warning events, logs of anything crash-looping, Velero's backups and restores |

**Not yet:** Alertmanager routes nowhere until a team connects its pager. The upgrade job (previous release, upgraded in place, data checked) starts with the first release after v1.0.0.

## Security

The full picture, threat by threat, is in the [threat model](threat-model.md). In short:

| Practice | Evidence |
|---|---|
| Admission enforced by the API server itself, not only by a webhook | e2e 4b: Kyverno scaled to zero, every planted manifest still refused |
| Images by digest; Pod Security `restricted` for tenants | e2e steps 1, 2 and 4; static checks with planted violations |
| Tenants confined to one namespace, with an allow-list of kinds and no RBAC, and syncs that run with tenant rights only | e2e 5b: three escape attempts refused by Argo CD, and the API server's answers for team-b's sync account; `check-argocd.py` |
| Default-deny networking per tenant | e2e step 5 |
| Access entries only, KMS for Secrets, IMDSv2 with hop limit 1, Pod Identity per controller | `terraform test`, 24 planted violations (mocked plan) |

**Not yet:** signature and SBOM verification at admission, runtime detection, and encryption between pods.

## Reliability

| Practice | Evidence |
|---|---|
| A deleted namespace comes back with its data | e2e step 7: back up, delete the namespace and its volume, restore, read back a marker written before the backup |
| An objective that pages before users notice | multi-window burn-rate alerts, unit-tested with promtool and made to fire in the cluster (e2e 6b) |
| No single replica on the request path (EKS) | Kyverno's admission controller at three replicas and its other controllers at two (`platform/values/kyverno/eks.yaml`); the demo frontend at two replicas with anti-affinity and a PodDisruptionBudget |
| Three availability zones | `availability_zone_count = 3` (mocked plan) |
| Rollback is a commit | `docs/runbooks/rollback.md`: move `platform_revision` back |

**Not yet, and chosen:** one NAT gateway by default (`nat_gateway_count = 1`) makes outbound traffic depend on one zone; setting it to 3 removes that at about three times the NAT cost (ADR 11). Backups stay in the cluster's region; there is no cross-region copy. The daily proof runs on a single-node kind cluster, so zone failure itself is not exercised.

## Performance efficiency

| Practice | Evidence |
|---|---|
| Nodes sized to the pods that need them | Karpenter NodePool, instance generation above 5, Spot and On-Demand (`manifests/aws/karpenter.yaml`) |
| Graviton for the system node group | `terraform test`: system nodes run Amazon Linux 2023 on Graviton (mocked plan) |
| Latency measured against an objective | the demo's latency SLO, 99% of requests within 500 ms |
| Request paths visible | traces from the demo become span metrics in Prometheus (ADR 8) |

**Not yet:** no load test. Nothing here says how many requests the Gateway or the demo can serve.

## Cost optimization

| Practice | Evidence |
|---|---|
| A cost estimate before anything is built | the README's table: about $0.32 an hour, about $235 a month before workloads, logs and traffic |
| Standard support only | `terraform test`: no silent move to extended support pricing at six times the control plane price (mocked plan) |
| Spot first, consolidation on | Karpenter `consolidationPolicy: WhenEmptyOrUnderutilized`, CPU and memory limits on the NodePool |
| One tenant cannot spend the cluster | a ResourceQuota per tenant, no LoadBalancer Service and no Gateway of its own |
| A real-cloud run cannot leave resources behind | designed, not built: ADR 10 (teardown, a residue sweep, budget alerts, a kill switch, a cost report per run) |
| The daily proof costs nothing in cloud spend | kind on a GitHub-hosted runner |

**Not yet:** cost per tenant. Nothing allocates the bill to teams (OpenCost would).

## Sustainability

| Practice | Evidence |
|---|---|
| Graviton on the system nodes | `terraform test` (mocked plan) |
| Empty and underused nodes are removed | Karpenter consolidation |
| Test clusters exist only while a test runs | kind on CI runners, deleted with the runner |

**Not yet:** no measurement. Nothing here reports energy or carbon.

## How to explain this to a customer

The platform has been checked against the same six questions AWS uses to review an architecture, and every answer points at a test rather than a promise. Where something is missing, such as cost per team, load testing, or a copy of backups in a second region, the review says so, together with what it would take to add it.
