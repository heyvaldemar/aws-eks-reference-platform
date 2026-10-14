# bootstrap-aws

What ADR 10 asks of the AWS account before the first validation run, applied once by the maintainer from his own machine. CI never applies this.

## What it creates

| Resource | Why |
|---|---|
| GitHub OIDC provider | workflows get short-lived credentials; no access key exists anywhere |
| `platform-validation-create` role | assumed only by this repository's `aws-validation` environment; creates and destroys a run |
| `platform-validation-sweep` role | assumed only by the `aws-sweeper` environment; reads everything, deletes what a run makes, creates nothing |
| Guardrails on both roles | no IAM users or access keys, no billing or budget changes, no change to the bootstrap's own roles, state bucket or zone, one region |
| State bucket | versioned, encrypted, private, TLS only; one state file per run |
| Validation zone | delegated once, kept between runs, so certificates issue for real |
| Budget with alerts at $5 and $10 | e-mail to the maintainer |
| Kill-switch at $15 | AWS Budgets attaches deny-all to the creation role; the sweeper keeps working |

Standing cost: about $0.50 a month for the hosted zone and cents for the state bucket.

## Applying it

1. In a new, standalone AWS account paid personally (ADR 10), sign in as an administrator, not as root, for example with IAM Identity Center and `aws sso login`.
2. From this directory:

   ```bash
   terraform init
   terraform apply -var alert_email=<your address> -var validation_domain=eks-validation.<a domain you control>
   ```

3. Delegate `validation_domain` once: create an NS record for it in the parent zone with the four `name_servers` from the output.
4. Keep this directory's `terraform.tfstate` somewhere safe and private (it holds no credentials, but it is the only record of the bootstrap). It is local on purpose: this module creates the bucket every other state lives in.
5. Put the outputs into the GitHub environments, as variables (none is a secret). In GitHub's environment settings, make `aws-validation` require the maintainer's approval, so a dispatched run waits for a second yes before it spends anything:

   | Environment | Variables |
   |---|---|
   | `aws-validation` | `AWS_REGION`, `AWS_CREATE_ROLE_ARN`, `TF_STATE_BUCKET`, `VALIDATION_DOMAIN`, `VALIDATION_ZONE_ID` |
   | `aws-sweeper` | `AWS_REGION`, `AWS_SWEEP_ROLE_ARN`, `TF_STATE_BUCKET` |

## After the kill-switch fires

Runs fail with AccessDenied from then on, which is the point. To re-enable them, the maintainer detaches `platform-validation-deny-all` from `platform-validation-create` himself, after reading why the month reached $15: no workflow role can do it.

## Checks

`terraform test` runs the promises above against a mocked provider, and `tests/plants.tsv` breaks each one on a copy to show the test fails (`python3 tests/plant_violations.py bootstrap-aws` from `terraform/`). Both run in the Verification workflow.
