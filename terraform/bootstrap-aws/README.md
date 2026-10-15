# bootstrap-aws

What ADR 10 asks of the AWS account before the first validation run, applied once by the maintainer from his own machine. CI never applies this.

## What it creates

| Resource | Why |
|---|---|
| GitHub OIDC provider | workflows get short-lived credentials; no access key exists anywhere |
| `platform-validation-create` role | assumed only by this repository's `aws-validation` environment; creates and destroys a run |
| `platform-validation-sweep` role | assumed only by the `aws-sweeper` environment; reads everything, deletes what a run makes, creates nothing |
| Guardrails on both roles | no IAM users or access keys, no billing or budget changes, no change to the bootstrap's own roles, policies, state bucket or zone, one region; roles changed or passed only under the run's name prefix |
| Permissions boundary | every role a run creates must carry it, and it carries the guardrails' denies, so creating a role is not a way around them |
| State bucket | versioned, encrypted, private, TLS only; one state file per run |
| Validation zone | delegated once, kept between runs, so certificates issue for real |
| Budget with alerts at $10 and $20 | e-mail to the maintainer |
| Kill-switch at $30 | AWS Budgets attaches deny-all to the creation role; the sweeper keeps working |

Standing cost: about $0.50 a month for the hosted zone and cents for the state bucket.

## Applying it

1. In an AWS account paid personally that holds nothing else (ADR 10), standalone or a member account of your own AWS Organization, sign in as an administrator, not as root: for example with IAM Identity Center and `aws sso login`, or from the management account through the member account's `OrganizationAccountAccessRole`. If the account you have is the one you use for everything, create a member account for this rather than applying it there: the workflow roles can delete what they did not make. Promotional credits are fine; the budget counts usage before them.
2. From this directory:

   ```bash
   terraform init
   terraform apply -var alert_email=<your address> -var validation_domain=eks-validation.<a domain you control>
   ```

   For a repository other than this one, also pass `repository` and `subject_repository`: the repository as GitHub writes it into the OIDC token's subject, from `gh api repos/OWNER/NAME/actions/oidc/customization/sub --jq .sub_claim_prefix` without the leading `repo:`. A repository created or renamed after 15 July 2026 gets the immutable form, `owner@OWNER_ID/name@REPO_ID`, and a trust policy written for `owner/name` refuses every run.
   Since 30 September 2026 AWS Budgets e-mails only addresses that are verified: the apply sends a verification e-mail from an `@aws.com` sender to `alert_email`, valid for 12 hours, and its link works only while you are signed in to this account's console. Until it is verified, the alerts and the kill-switch notice reach nobody; the kill-switch itself still fires. A lapsed link is sent again with `aws notificationscontacts send-activation-code --arn <the contact's ARN>` (`aws notificationscontacts list-email-contacts` lists it and its status).
3. Delegate `validation_domain` once: create an NS record for it in the parent zone with the four `name_servers` from the output.
4. Keep this directory's `terraform.tfstate` somewhere safe and private (it holds no credentials, but it is the only record of the bootstrap). It is local on purpose: this module creates the bucket every other state lives in.
5. Put the outputs into the GitHub environments, as variables (none is a secret), and limit both environments to the `main` branch. Not a required reviewer: the teardown job runs in the same environment, and a teardown that waits for a person is how resources keep billing. The run itself asks for a typed confirmation when it is dispatched:

   | Environment | Variables |
   |---|---|
   | `aws-validation` | `AWS_REGION`, `AWS_CREATE_ROLE_ARN`, `TF_STATE_BUCKET`, `VALIDATION_DOMAIN`, `VALIDATION_ZONE_ID`, `IAM_PERMISSIONS_BOUNDARY` |
   | `aws-sweeper` | `AWS_REGION`, `AWS_SWEEP_ROLE_ARN`, `TF_STATE_BUCKET` |

6. Set the repository variable `AWS_VALIDATION_ENABLED` to `true`. The daily sweeper and the weekly run start; any other value stops both without a commit.

## What it does not stop

The creation role is an administrator inside the boundary. A workflow that runs as it could create a role under the run's prefix, with the boundary, that trusts someone outside the account; the kill-switch would not reach that role, because AWS Budgets attaches its policy to named roles only. The protection there is who can change what the workflow runs: it runs only from `main`, by a manual dispatch from someone with write access to this repository or by the weekly schedule, which runs `main` as it is. The sweeper deletes roles under the prefix that outlive their run.

## After the kill-switch fires

Runs fail with AccessDenied from then on, which is the point. To re-enable them, the maintainer detaches `platform-validation-deny-all` from `platform-validation-create` himself, after reading why the month reached $30: no workflow role can do it.

## Checks

`terraform test` runs the promises above against a mocked provider, and `tests/plants.tsv` breaks each one on a copy to show the test fails (`python3 tests/plant_violations.py bootstrap-aws` from `terraform/`). Both run in the Verification workflow.
