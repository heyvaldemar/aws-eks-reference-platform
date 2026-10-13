# Handover and day 2

What the team that owns the platform after the engagement does, how often, and where each instruction lives. The engagement is over when that team has done every routine below at least once without help.

## Who owns what

| Area | Owner | Control |
|---|---|---|
| `platform/`, `manifests/`, `bootstrap/`, `terraform/` | the platform team | write access to these paths is the platform's real boundary: whoever can push here controls every tenant |
| `apps/<team>/` | that team | its Argo CD project and its deployer account limit it to its own namespace and an allow-list of kinds |
| The AWS account | the platform team, with the customer's cloud owner | access entries and the two roles of [ADR 10](../decisions/0010-aws-validation-runs.md) |
| Pages from the SLO alerts | the on-call rotation agreed in discovery | [incident runbook](../runbooks/incident.md) |

## The routine

| How often | What | Where |
|---|---|---|
| Every change | the e2e suite and the static checks pass before a change reaches the cluster | the kind e2e and Verification workflows |
| Daily | the scheduled e2e run is green; a red run is read the same day | the workflow's summary |
| Weekly | Dependabot's grouped pull requests and the freshness report for charts, images and tools are reviewed and merged | Verification's weekly freshness job |
| Weekly | the hands-on exercises still run as written | the hands-on guide workflow |
| Monthly | one restore of a real tenant, timed against the RTO | [restore runbook](../runbooks/restore.md) |
| Monthly | the bill against the [sizing](sizing.md) estimate; requests against measured use | Cost Explorer, Grafana |
| Before each Kubernetes version leaves standard support | the cluster upgraded, not moved to extended support | [upgrade runbook](../runbooks/upgrade.md), [ADR 11](../decisions/0011-cost-defaults.md) |
| After any incident | what changed, what was seen, what is changed so it is seen earlier | [incident runbook](../runbooks/incident.md) |

## Before the engagement ends

- [ ] The owning team has onboarded a tenant from the template without help.
- [ ] The owning team has upgraded one component through a pull request, and rolled it back.
- [ ] The owning team has restored a tenant on production and recorded how long it took.
- [ ] Every page goes to a person who has acknowledged one.
- [ ] Admin passwords for Argo CD and Grafana are rotated, and the plan for SSO in front of them has an owner and a date.
- [ ] The [known limitations](../../README.md#known-limitations) are read and either accepted in writing or scheduled.
- [ ] The success plan's acceptance run on production is attached to the sign-off, with its commit.
