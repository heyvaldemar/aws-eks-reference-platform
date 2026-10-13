# Engagement pack

The documents a post-sales engagement would put in front of a customer adopting this platform, written for one fictional customer so every page has numbers in it instead of blanks. Nothing here describes a real company or a real deployment; the platform does not run in production anywhere.

**The customer, as assumed throughout:** a software company of about 150 engineers that runs some 40 internal services as Docker Compose stacks on a dozen virtual machines. Each team deploys by SSH. Backups are a cron job per machine that nobody has restored from. An auditor has asked two questions the company cannot answer with evidence: which code runs in production, and how long a restore takes. The company has an AWS organization and wants teams to ship without a ticket to the operations team.

| Document | Read it when | Who it is for |
|---|---|---|
| [Executive summary](executive-summary.md) | first | the sponsor |
| [Discovery](discovery.md) | before anything is built | platform lead, security, each team lead |
| [Success plan](success-plan.md) | when scope is agreed | everyone who signs the acceptance |
| [Adoption plan](adoption-plan.md) | when the success plan is signed | platform team, team leads |
| [Sizing and cost](sizing.md) | before the first AWS account is touched | sponsor, finance, platform lead |
| [Handover and day 2](handover.md) | before the engagement ends | the team that will own the platform |

Every acceptance criterion in the success plan is a check that already runs in this repository: an e2e step, a static check with a planted violation, or a runbook drill. The engagement does not invent its own proof; it runs the same suite against the customer's cluster and agrees in advance what passing means.
