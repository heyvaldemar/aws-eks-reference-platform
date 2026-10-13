# Success plan

What "done" means, agreed before the work starts. Each criterion is a check that already runs in this repository, so passing is not a matter of opinion: the same suite runs against the customer's cluster, and its output is the acceptance record.

`tests/e2e/run.sh` is the suite; its step numbers are used below. "Upgrade job" is the second job of the kind e2e workflow, which installs the previous release, writes a marker, upgrades to the commit under test and requires the marker and every check.

## Acceptance criteria

| # | Outcome | Accepted when | Proof | Owner |
|---|---|---|---|---|
| 1 | Only known code runs | every running image is referenced by digest, and an image by tag is refused | e2e 1 and 4 | platform lead |
| 2 | Teams cannot weaken the rules | each planted violation (a privileged pod, no memory limit, an image by tag, no probes, a tenant namespace without Pod Security) is refused, and still refused with Kyverno stopped | e2e 4 and 4b | security |
| 3 | Pod Security holds | tenant namespaces enforce `restricted`, platform namespaces what they declare | e2e 2 | security |
| 4 | Services are reachable only as intended | HTTPS through the Gateway with the platform's certificate, HTTP redirects, and every path no NetworkPolicy opens is refused | e2e 3 and 5 | platform lead |
| 5 | A team onboards itself | a new tenant from `apps/_template` is served on its own hostname, cannot reach another tenant's secrets, and its Argo CD project refuses kube-system, another namespace and a RoleBinding to admin | e2e 5b | team lead of the pilot |
| 6 | Problems page someone | metrics and traces arrive, the SLO rules load, and a forced failure fires the fast-burn alert | e2e 6 and 6b | on-call lead |
| 7 | Data comes back | a tenant and its volume are deleted and restored, and data written before the backup reads back; the drill's duration is within the agreed RTO | e2e 7, [restore runbook](../runbooks/restore.md) | platform lead |
| 8 | Upgrades do not lose data | the previous release upgraded in place keeps its marker and passes every check | upgrade job | platform lead |
| 9 | GitOps reads releases | Argo CD resolves a release tag with the credential the cluster holds | e2e 8 | platform lead |
| 10 | The AWS controls are what they say | access entries only, KMS for Secrets, IMDSv2 with hop limit one, Pod Identity per controller; each of 24 planted violations fails `terraform test` | `make check`, then the validation run of [ADR 10](../decisions/0010-aws-validation-runs.md) on the customer's account | security |
| 11 | Every static check can fail | each of 25 planted violations in rendered manifests is caught | `make check` | platform lead |

## Agreed during discovery

These have no default; the customer sets them and the success plan records them.

| Criterion | Value |
|---|---|
| RTO for the most critical tier, measured by the restore drill | _from discovery_ |
| RPO, which sets Velero's schedule | _from discovery_ |
| Monthly cost ceiling before workloads | _from discovery_ |
| Weeks from pilot start to the pilot team's first unassisted deployment | _from discovery_ |

## How acceptance is recorded

Phase exit is a run of the suite on the customer's cluster, attached to the phase's sign-off with the commit it ran on. A criterion that fails holds the phase; it is not waived in a meeting. A criterion the customer no longer wants is removed from this table with the reason, before the run.
