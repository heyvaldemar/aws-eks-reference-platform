# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- `bootstrap.sh` stores `PLATFORM_REPO_TOKEN` without a trailing newline. It was fed through a here-string, which appends one, and Argo CD sent the token as stored when it listed the remote's refs, so an Application pinned to a tag or a branch of a private repository failed with "Invalid username or token". A commit SHA needs no listing, which is why the e2e run, pinned to a commit, never saw it; the upgrade job, the first to read a tag, did.

### Added

- e2e step 8: Argo CD resolves the latest release tag with the credential the cluster holds.

## [1.0.0] - 2026-10-12

### Added

- The platform as Argo CD ApplicationSets keyed on the cluster Secret: Envoy Gateway, cert-manager, External Secrets, Kyverno, kube-prometheus-stack, the OpenTelemetry Collector and Velero on every cluster; Karpenter, the AWS Load Balancer Controller and ExternalDNS on EKS.
- Kyverno CEL policies compiled into native ValidatingAdmissionPolicies: images by digest, requests and memory limits, probes, restricted Pod Security for tenants; a generated default-deny NetworkPolicy per tenant namespace.
- Tenants: one directory under `apps/` per team. The platform creates the namespace, its labels and quota, and an Argo CD project whose only destination is that namespace and which allows only the kinds a service needs, no RBAC among them. Every sync runs as the account its project names (Argo CD sync impersonation, enforced); a tenant's runs as a deployer whose Role grants the same kinds in its own namespace. The team's directory holds only what runs inside it.
- An SLO for the demo (availability and latency) with multi-window burn-rate alerts, unit-tested with promtool and shown to page in the kind e2e run.
- Terraform for EKS 1.37: VPC, cluster with access entries and KMS-encrypted Secrets, Graviton system node group, managed add-ons, Pod Identity for six controllers, Karpenter's AWS side, the Velero bucket and the Route 53 zone. Tested against a mocked provider; not yet applied to a real account.
- The kind e2e suite, run on every change and daily, and its upgrade job from the previous release.
- Static checks on the rendered manifests and the Terraform, each shown its planted violation.
- Runbooks for upgrade, rollback, restore and incident, and a hands-on guide whose three exercises run as written every week.
- Thirteen decision records, each ending with how the choice would be explained to a customer; a threat model with the check behind every control; a Well-Architected review with the evidence and the gaps.

[Unreleased]: https://github.com/heyvaldemar/aws-eks-reference-platform/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/aws-eks-reference-platform/releases/tag/v1.0.0
