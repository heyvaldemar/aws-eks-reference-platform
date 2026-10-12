# 10. AWS validation runs: guards and cost reporting

- Status: accepted, design only (nothing in this ADR is built or enabled until the owner says so)
- Date: 2026-10-11

## Context

ADR 9 makes a real EKS run manual and occasional. A run creates resources billed by the hour (about $0.32 an hour before workloads, see the README), in an account that must never be confused with anyone else's. The failure to design against is not a failed test; it is a cluster nobody remembers, billing for a month.

## Decision

These are the conditions under which a run would be built and enabled. Each is required; none is optional.

**Account.** A separate AWS account paid personally by the maintainer, standalone, not a member of any employer's organization and not linked to one. Nothing else runs in it.

**Trigger.** `workflow_dispatch` only, before a release. Never a schedule, never a push.

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
7. AWS Budgets on the account: e-mail alerts to the maintainer at $5 and $10 of monthly actual cost.
8. A kill-switch at $15: a Budgets action that attaches a deny-all policy to the creation role. Runs after that fail instead of spending; the sweeper keeps cleaning.

## Consequences

- The worst case is bounded twice: by the 3-hour sweeper for anything a run leaves behind, and by the $15 kill-switch for anything that keeps creating.
- Every run reports what it cost, so the README's estimate can be replaced by a measured number.
- Building it needs the account, the two roles, the budgets and the two workflows. None of it exists yet, and none of it will until the maintainer says so.

## How to explain this to a customer

Real cloud tests run only when a person starts them, in an account that exists for nothing else, with a spending cap that switches off the ability to create anything once it is reached. Every test cleans up after itself, a separate job deletes anything a failed test left behind within three hours, and every run reports what it cost. You would set up the same guards before letting any automation spend in your account.
