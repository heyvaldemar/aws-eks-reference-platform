# 2. Karpenter on a small system node group, not EKS Auto Mode

- Status: accepted
- Date: 2026-10-11

## Context

Workloads need EC2 capacity that follows demand. EKS offers two managed answers: Auto Mode, where AWS runs Karpenter, the load balancer controller and the EBS driver for you and charges a management fee per instance; and running Karpenter yourself. A reference platform is also something a team reads to learn how the pieces fit.

## Decision

Karpenter runs in the cluster, installed by Argo CD, on a fixed managed node group of two Graviton instances (`t4g.large`) that also carries Argo CD and the first add-ons. Karpenter provisions everything else from one NodePool: arm64 and amd64, Spot first with On-Demand as the fallback, instance generation above 5, nodes replaced at most every 30 days, consolidation when empty or underused. Interruption warnings reach it through an SQS queue fed by EventBridge.

## Consequences

- No per-instance management fee on top of EC2.
- The NodePool and EC2NodeClass are in Git (`manifests/aws/karpenter.yaml`), so capacity rules are reviewed like any other change.
- Karpenter, the load balancer controller and the EBS driver are ours to upgrade. The weekly freshness job reports new versions; the upgrade runbook covers them.
- The system node group is a fixed cost (about $98 a month) that Auto Mode would not have. It exists because something has to run before Karpenter can provision anything.

## Alternatives

- **EKS Auto Mode.** Less to operate, and the right default for a team that does not want to own node lifecycle. It hides the NodePool and EC2NodeClass design that a customer will ask about, and adds a fee to every instance.
- **Cluster Autoscaler with managed node groups.** Scales in fixed instance shapes per group and reacts slower than Karpenter's per-pod bin packing.
- **Karpenter on Fargate.** Removes the system node group, but every add-on that must run before Karpenter would then need its own Fargate profile.

## How to explain this to a customer

You pay EC2 prices for the machines your workloads run on, chosen per pod from many instance types, cheapest first and Spot where it is safe, and replaced every month so they stay patched. The rules for that are in your repository, not in a console. The trade is that the autoscaler is software your team upgrades; if you would rather AWS did that for a fee per instance, EKS Auto Mode is the same idea run for you.
