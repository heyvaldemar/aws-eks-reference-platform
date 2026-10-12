# 11. Cost defaults: one NAT gateway, Graviton, standard support only

- Status: proposed
- Date: 2026-10-11

## Context

The defaults decide what a first `make eks-up` costs and what it protects against. A reference that defaults to the most resilient option everywhere teaches people to over-spend; one that hides its trade-offs teaches worse.

## Decision

- **One NAT gateway** by default (`nat_gateway_count = 1`). Private subnets in every zone leave through it. Set it to the number of zones for egress that survives the loss of a zone.
- **Graviton** for the system node group (`t4g.large`), and arm64 first in Karpenter's NodePool, which also allows amd64 for images without an arm64 build.
- **Standard support only** (`upgrade_policy.support_type = "STANDARD"`). When a Kubernetes version leaves standard support, EKS would otherwise move the cluster to extended support, where the control plane costs six times as much per hour; with STANDARD it is upgraded instead.
- **Logs with a retention** of 30 days for the control plane and VPC flow logs, all five control-plane log types on.
- The Velero bucket can be destroyed with its backups in it (`velero_bucket_force_destroy = true`), so `make eks-down` is one command. Set it to false for any cluster whose backups matter.

## Consequences

- About $33 a month saved against three NAT gateways, for a single-zone dependency on outbound traffic. Inbound traffic and the control plane are unaffected.
- Graviton instances cost less per vCPU than comparable x86; a multi-arch image is required for anything pinned to arm64 nodes.
- A forced upgrade is a planned change somebody has to make; an extended-support bill is a surprise nobody budgeted.
- The audit log is the largest log line on most bills; retention caps it, turning it off would hide the record an incident needs.

## How to explain this to a customer

The defaults are the cheapest setup that is still secure, and each place where we chose cost over resilience is one setting you can change: three NAT gateways instead of one for zone-proof outbound traffic, for about $33 a month more. We also pin the cluster to standard support, so an old Kubernetes version becomes an upgrade you plan rather than a control-plane bill six times larger.
