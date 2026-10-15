# 10. AWS validation runs: guards and cost reporting

- Status: accepted; built 2026-10-14; weekly runs approved 2026-10-14
- Date: 2026-10-11

## Context

ADR 9 makes a real EKS run manual and occasional. A run creates resources billed by the hour (about $0.32 an hour before workloads, see the README), in an account that must never be confused with anyone else's. The failure to design against is not a failed test; it is a cluster nobody remembers, billing for a month.

## Decision

These are the conditions under which a run would be built and enabled. Each is required; none is optional.

**Account.** A separate AWS account paid personally by the maintainer: standalone, or a member account in the maintainer's own AWS Organization, never in an employer's organization or linked to one. Nothing else runs in it. The workflow roles can create and delete what a run needs, and the sweeper deletes on a schedule; in an account that also holds other work, those rights would reach it. The budget measures usage before credits, so an account on promotional credits still reaches its thresholds.

**Trigger.** `workflow_dispatch` only, before a release. Never a schedule, never a push. (Since 2026-10-14 also weekly; see the last section.)

**Identity.** GitHub OIDC into two IAM roles, each trusted only for this repository and one GitHub environment:

- a *creation* role for `terraform apply` and the e2e run;
- a *delete-only* role for the sweeper below, with permission to describe and delete, and nothing to create.

**Inside every run.**

1. A hard `timeout-minutes` on the job.
2. Every resource tagged with `run-id` (the Terraform `run_id` variable, the GitHub run ID).
3. Teardown in a separate job with `if: always()`: `make eks-down`, so it runs whether the test passed, failed or was cancelled.
4. After teardown, a residue search: the Resource Groups Tagging API for anything still tagged with this `run-id`, plus the resource types it misses (load balancers, ENIs, EBS volumes). Anything found fails the run and is listed.
5. A cost report in the job summary: resource-hours times list prices at the end of the run, and the next day the same `run-id` reconciled against Cost Explorer once the bill catches up.

**Outside every run.**

6. A daily sweeper workflow, using the delete-only role, that destroys anything tagged with a `run-id` older than 3 hours and reports what it removed. It does not depend on the creation role, so the kill-switch below does not stop it.
7. AWS Budgets on the account: e-mail alerts to the maintainer at $10 and $20 of monthly actual cost.
8. A kill-switch at $30: a Budgets action that attaches a deny-all policy to the creation role. Runs after that fail instead of spending; the sweeper keeps cleaning.

## Consequences

- The worst case is bounded twice: by the 3-hour sweeper for anything a run leaves behind, and by the $30 kill-switch for anything that keeps creating.
- Every run reports what it cost, so the README's estimate can be replaced by a measured number.
- Building it needs the account, the two roles, the budgets and the two workflows.

## Built, 2026-10-14

The maintainer said yes on 2026-10-14. What exists, all of it checkable without an account:

- `terraform/bootstrap-aws/`: the OIDC provider, the two roles each trusted for one GitHub environment, guardrails on both, a permissions boundary every role a run creates must carry (without it, a role with AdministratorAccess escapes any deny by creating another role), the state bucket, a persistent validation zone delegated once, the budgets and the kill-switch. Its `terraform test` and ten planted violations run in Verification.
- `.github/workflows/eks-validation.yml`: guards 1 to 5, with the run's state and variables in the bucket and `tests/eks/run.sh` as the check. The cleanup of what controllers made runs from the job that created the cluster, whose address the API allows; if that job dies first, the teardown adds its own address and does the same. The environment is limited to `main` rather than to a reviewer, because the teardown runs in it and must not wait for a person.
- `.github/workflows/eks-sweeper.yml`: guard 6, daily, with yesterday's bill in its summary, which is the day-later reconciliation of guard 5 until the run-id cost allocation tag is active.

Not yet: the account. Until it exists and a run has passed, the README keeps saying that the EKS path has not been applied.

## Weekly, 2026-10-14

The maintainer said yes to a weekly run on 2026-10-14. A run that passed once says the EKS path worked on that day. Providers, add-ons and AWS itself move every week, and a run nobody repeats ages into a claim.

- **Trigger.** Every Monday at 01:17 UTC, besides the manual dispatch. It runs only while the repository variable `AWS_VALIDATION_ENABLED` is `true`, which also gates the sweeper, so switching both off needs no commit. A push or a pull request still never starts a run.
- **Budget.** Alerts at $10 and $20, the kill-switch at $30; they were $5, $10 and $15 for runs by hand. Four or five runs at the estimated $1 to $3 each come to $4 to $15 a month. The alerts say whether a month is ordinary, and the kill-switch stays a ceiling for mistakes, not a budget. The first runs replace the estimate with a measured number.
- **The fleet allows exactly this.** Its conformance check accepts a scheduled apply only at most weekly and behind a repository variable; a daily one fails it.
- **The account.** A member account in the maintainer's own AWS Organization that holds nothing else.

## How to explain this to a customer

Real cloud tests run once a week and when a person starts them, in an account that exists for nothing else, with a spending cap that switches off the ability to create anything once it is reached. Every test cleans up after itself, a separate job deletes anything a failed test left behind within three hours, and every run reports what it cost. You would set up the same guards before letting any automation spend in your account.
