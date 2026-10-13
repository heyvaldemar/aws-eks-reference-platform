# Sizing and cost

An estimate from list prices, made before any account is touched. Phase 1 replaces it with a measured bill; until then every number here is arithmetic on stated assumptions, and the assumptions are the part to argue with.

## The cluster before workloads

From the [README](../../README.md#what-it-would-cost), us-east-1 list prices:

| Item | Per month (730 h) |
|---|---|
| EKS control plane, standard support | $73 |
| 2 × t4g.large system nodes (Argo CD, Kyverno, the Gateway, monitoring) | $98 |
| 1 NAT gateway, before traffic | $33 |
| Network Load Balancer, before capacity units | $16 |
| EBS gp3, KMS keys, Route 53 zone, one secret | about $16 |
| **Total before workloads, logs and traffic** | **about $235** |

## The 40 services

**Assumptions**, from the customer profile in the [engagement pack](README.md), to be replaced by the inventory from [discovery](discovery.md):

- 40 services, one replica each, and a second replica for the third that are customer-facing: 53 pods.
- An average request of 0.25 vCPU and 512 MiB per pod: about 13 vCPU and 27 GiB requested.
- Karpenter packs them onto Graviton general-purpose nodes; m7g.xlarge (4 vCPU, 16 GiB) is the size used here.
- About 15% of each node goes to the kubelet, the system reservation and DaemonSets.

**Nodes:** 13 vCPU ÷ (4 × 0.85) = 3.8, so **four m7g.xlarge**, with memory to spare (64 GiB for 27 requested).

| Pricing | Per node-hour | Four nodes, per month |
|---|---|---|
| On-demand | $0.1632 | about $477 |
| Spot | about $0.096 | about $280 |

The on-demand price is AWS's list price for us-east-1. The Spot price is a reading from a public price index on 13 October 2026 and moves daily; Karpenter's NodePool tries Spot first and falls back to on-demand, so the real line lands between the two.

**Estimate: about $515 to $715 a month for the cluster and the 40 services**, before the lines below.

## What the estimate leaves out

- **NAT gateway data processing**, per gigabyte through it: image pulls are the first surprise. A pull-through cache or VPC endpoints for ECR and S3 move that traffic off the NAT gateway.
- **CloudWatch Logs ingestion.** The control plane's audit log is usually the largest log line; [ADR 11](../decisions/0011-cost-defaults.md) keeps 30 days.
- **Load balancer capacity units and data transfer out**, which follow traffic.
- **Databases.** A service whose database moves to RDS brings its own line; one that stays in the cluster brings a volume and a backup.
- **Images without an arm64 build.** They run on amd64 nodes, which cost more per vCPU than Graviton.

## What changes the number most

| Lever | Effect |
|---|---|
| The share of pods that tolerate Spot | the difference between the two rows above, for every node |
| Requests that match real use | phase 1's week of metrics shows them; requests set from Compose limits are usually too high |
| One NAT gateway or one per zone | $33 a month per gateway, against egress that survives the loss of a zone |
| Log retention and log types | the audit log is the one to keep; the others are a decision |
| A second cluster for non-production | about $235 a month before its own workloads; namespaces in one cluster cost nothing extra |
