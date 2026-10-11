# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The platform as Argo CD ApplicationSets keyed on the cluster Secret: Envoy Gateway, cert-manager, External Secrets, Kyverno, kube-prometheus-stack, the OpenTelemetry Collector and Velero on every cluster; Karpenter, the AWS Load Balancer Controller and ExternalDNS on EKS.
- Kyverno CEL policies compiled into native ValidatingAdmissionPolicies: images by digest, requests and memory limits, probes, restricted Pod Security for tenants; a generated default-deny NetworkPolicy per tenant namespace.
- Terraform for EKS 1.37: VPC, cluster with access entries and KMS-encrypted Secrets, Graviton system node group, managed add-ons, Pod Identity for six controllers, Karpenter's AWS side, the Velero bucket and the Route 53 zone. Tested against a mocked provider; not yet applied to a real account.
- The kind e2e suite, run on every change and daily, and its upgrade job from the previous release.
- Static checks on the rendered manifests and the Terraform, each shown its planted violation.
- Runbooks for upgrade, rollback, restore and incident, and a hands-on guide.
