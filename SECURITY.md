# Security policy

## Supported versions

| Version | Supported |
|---|---|
| The latest release | yes |
| `main` | yes |
| Older releases | no |

## Reporting a vulnerability

Report privately through GitHub: **Security → Report a vulnerability** on this repository. Email to v@valdemar.ai also works. The process is described at [heyvaldemar.com/security](https://heyvaldemar.com/security/).

You can expect an acknowledgment within 7 days. There is no bounty program; valid, responsibly disclosed reports are credited in the changelog. Please do not open public issues for security reports.

## What this repository is

A reference architecture, not a hosted service and not a product with users' data. A vulnerability here is most likely a default that leaves a cluster built from it weaker than the README says: an IAM permission broader than it needs, a policy that admits what it should refuse, a pin that does not pin.

## Supply chain

- Container images are pinned by digest everywhere, and CI fails on one that is not (`scripts/check-images.py`, and every running pod in the e2e suite).
- GitHub Actions are pinned by commit SHA; CLI tools by version and sha256 (`tools.lock`); CI images by digest (`ci-images.pins`); Terraform providers by `.terraform.lock.hcl`.
- Each release carries a `git archive` of the tag, a keyless Cosign signature over it and SLSA provenance, made by GitHub Actions with a short-lived identity and no stored key. The README shows how to verify one.

## Credentials

No credential is stored in this repository or in its CI. On kind, the only secrets (the S3 keys shared by SeaweedFS and Velero) are generated at bootstrap and exist only in the cluster; Grafana's admin password is generated in the cluster by External Secrets. On EKS, controllers get AWS permissions through EKS Pod Identity and people through EKS access entries; there are no access keys.
