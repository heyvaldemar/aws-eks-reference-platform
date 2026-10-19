# Working on this repository as an agent

Most of the code here is written by an AI agent, and the decisions and the verification are the maintainer's. This file is what the agent is held to. A reviewer can hold it to the same rules.

## What this repository claims

Every row of the README's "What is proven, and how" table is a check that fails the build when the claim stops being true: `tests/e2e/run.sh` on kind, `scripts/validate.sh` and the Terraform tests (`terraform/tests/`, `terraform/bootstrap-aws/tests/`) in Verification, `scripts/check-freshness.py` weekly, `tests/e2e/hands-on.sh` for the guide, and `tests/eks/run.sh` on AWS. A claim with no check is not written. Proven on kind, proven against a mocked AWS provider and proven on a real AWS account are three different claims, and the text says which one it makes. It is a reference architecture, not a product, and nothing says otherwise: no wording that anyone runs it for real workloads, and no outside approval it does not hold (the fleet's conformance check refuses that wording).

`docs/threat-model.md`, `docs/well-architected.md` and `docs/engagement/success-plan.md` cite e2e steps by number. Renumbering or removing a step in `tests/e2e/run.sh` updates them in the same commit.

## Before changing anything

- Read the decision record under `docs/decisions/` that covers it. A change that alters a decision adds a record that supersedes it, or a dated section at the end of the existing one (ADR 9 and ADR 10 have them); what a record already says is not rewritten. Every record ends with how the choice is explained to a customer.
- `make check` runs the static checks (`scripts/validate.sh`). Then `python3 tests/static/plant_violations.py` shows each one its planted violation from `tests/static/plants.tsv`, and must end with every plant caught, none missed, none stale.
- A policy in `policies/` needs a test under `policies/tests/<name>/` with at least one expected `fail`, and must compile to a native ValidatingAdmissionPolicy so admission holds while Kyverno is down (`scripts/check-policy-tests.py`).
- A tenant change keeps `apps/_template`, `apps/team-b` and `tools/kubectl-tenant` in step: the Go tests rebuild `apps/team-b` from the template and require it to match, and read the reserved names from `platform/tenant/values.yaml`.

## A check is trusted only after it has failed

A new or changed check ships with the violation it exists for, where its kind of check keeps them:

- static checks: a row in `tests/static/plants.tsv`;
- Terraform: a row in `terraform/tests/plants.tsv` or `terraform/bootstrap-aws/tests/plants.tsv`, run by `terraform/tests/plant_violations.py`;
- admission: a manifest in `tests/e2e/plants/` whose `# expect:` line names what refuses it, while `compliant-pod.yaml` is still admitted;
- Kyverno policies: an expected `fail` in the policy's test; SLO alerts: a case in `tests/slo/demo-slo.test.yaml`; `kubectl tenant check`: a case in `TestCheckFindsEachViolation`.

Every refusal in the e2e is paired with a control that must be accepted, so a check cannot pass because something refuses everything. A plant whose text is no longer in its file is reported stale and fails the run. Where no plant fits, break the thing on a branch, run the e2e, and record the failing output in the commit message. A check that has never been seen to fail proves nothing. A new check in `tests/eks/run.sh` first runs for real in the scheduled weekly run, and until it has, the commit and the changelog say so.

## Proving a risky change

Run the kind e2e and Verification on a branch before it reaches main:

```bash
gh workflow run kind-e2e.yml --ref <branch>
gh workflow run verification.yml --ref <branch>
```

The kind e2e has two jobs: a fresh install, and the previous `v*` release upgraded to the branch. Argo CD reads this repository at the commit under test, so the branch has to be pushed; `make up` then `make test` run the same suite on a local kind cluster under the same condition. A change to `docs/hands-on.md` or `tests/e2e/hands-on.sh` also needs `gh workflow run hands-on.yml --ref <branch>`. A pull request to main runs the kind e2e and Verification too, unless it changes only `docs/` or Markdown.

A Terraform change is proved by `terraform test` against a mocked provider in Verification. Nothing but the EKS run needs an AWS account or AWS credentials.

`scripts/status.py` reads runs on main only, never pull requests, so branch runs never touch the badges. A day on main counts as green by its last run: a red run on main is diagnosed, not re-run until it passes.

## Pins

Everything is pinned, and each pin has its place:

- charts: an exact `targetRevision` in `platform/appsets/<component>.yaml` (`scripts/check-argocd.py` refuses a range or a branch);
- images: by digest, in `platform/values/<component>/images.yaml` for the charts and inline in `apps/`, `manifests/` and `tests/e2e/`; `scripts/check-images.py` fails on any rendered image without one;
- the kind node image by digest in `kind/cluster.yaml`; CLI tools by version and sha256 in `tools.lock`; CI images in `ci-images.pins`; GitHub Actions by commit SHA (the SLSA generator by tag, which it requires);
- Terraform providers in `terraform/.terraform.lock.hcl` and `terraform/bootstrap-aws/.terraform.lock.hcl`, read with `-lockfile=readonly`; CI's Python package by hash in `.github/requirements-ci.txt`; Go modules in `tools/kubectl-tenant/go.sum`;
- EKS add-ons in `terraform/addons.tf`, at EKS's default except metrics-server, which is held on a named build with the reason beside it.

To move a chart, follow `docs/runbooks/upgrade.md`: render with `RENDER_CHART_DEFAULT_IMAGES=1` to see what the new chart pulls, and pin every image found by digest. The Kubernetes version moves in all its places at once: `KUBE_VERSION` in `scripts/validate.sh` and `scripts/render.py`, the node image in `kind/cluster.yaml`, `kubectl` in `tools.lock`, `kubernetes_version` in `terraform/variables.tf` and its assertion in `terraform/tests/posture.tftest.hcl`. Dependabot moves the Actions, the provider, the Python package and the Go modules; `scripts/check-freshness.py` reports every other pin weekly and changes nothing.

## Numbers

The badges are written by `.github/workflows/status.yml` to the `status` branch from the runs on main; nothing there is typed by hand. A number in the README, a decision record or a release is copied from the log or artifact of the run it names (the README names run 38695231460 on `7040995` for its EKS figures), never from memory or an earlier draft: `bd290e4` corrected three that were not. A count of plants is the row count of its `plants.tsv` and changes in the same commit. A cost from list prices says it is an estimate, as the README's table and `scripts/aws-cost-report.py` do. When runs disagree, find what changed (the runner, a pin, an upstream registry) before calling it noise. A gate is never loosened to get a run green.

## Releases

- Fill `CHANGELOG.md` `[Unreleased]` (Added, Changed, Fixed) in the same commit as the change.
- A release moves `[Unreleased]` under `## [X.Y.Z] - YYYY-MM-DD` in a `chore(release): vX.Y.Z` commit and is tagged `vX.Y.Z`. The kind e2e's upgrade job starts from the newest earlier `v*` tag, so each release is the starting point of every upgrade test after it.
- Tag only a commit on main whose kind e2e and Verification runs are green, and name them in the notes: what is new, what was found while building it, how it was checked, and an Upgrading section if anything needs a person. A release that says something about EKS names the EKS run behind it, as 1.2.0 does.
- Publishing the release runs `.github/workflows/release-assets.yml`, which attaches the tag's `git archive`, its keyless Cosign bundle and SLSA provenance. Then verify them the way a stranger would: `cosign verify-blob` with the release's `.sigstore.json`, as the README shows, and `slsa-verifier verify-artifact` with `--source-tag <tag>`.

## Writing

Plain and specific. No em dashes, no marketing words, no claim the evidence does not carry. Name runs, commits and files. Commit subjects follow the history's `type(scope): what changed` (`fix(eks): ...`, `chore(pins): ...`). Commits are authored `Vladimir Mikhalev <10498744+heyvaldemar@users.noreply.github.com>` and carry no AI attribution lines.

## Never

- Dispatch, re-run, or change the schedule or the gate of `.github/workflows/eks-validation.yml`, and never create, change or delete anything in AWS. It spends money, and the only approved run is the scheduled weekly one, gated by the repository variable `AWS_VALIDATION_ENABLED`, under budget alerts and a $30 kill-switch ([ADR 10](docs/decisions/0010-aws-validation-runs.md)). The same holds for `.github/workflows/eks-sweeper.yml`, which is left to its daily schedule, for the `AWS_VALIDATION_ENABLED` variable, for `make eks-up`, `make eks-down` and `make eks-bootstrap`, and for applying or destroying `terraform/` or `terraform/bootstrap-aws/` against an account.
- Print a raw rendered chart or a render diff to a log or the transcript: the AWS Load Balancer Controller and External Secrets charts render a private key into `out/`. Compare renders by object names and images, the way `docs/runbooks/upgrade.md` greps `image:`. Verification blanks every Secret's values (`scripts/redact-secrets.py`) before it uploads the render; never upload `out/` without that step.
- Print a secret or a credential, or pass one as a command-line argument. Pass it on stdin with `printf '%s'`, not a here-string, which appends a newline (the 1.0.1 fix in `bootstrap/bootstrap.sh`). On kind, `bootstrap/bootstrap.sh` makes the object store's keys inside the cluster; on AWS the workflows assume roles through GitHub OIDC and store no key. Terraform state can hold secrets: never print it or commit it.
- Turn off or weaken a check, a policy, a test or a gate to get a run green, or drop a plant its check has stopped catching.
- Write "weekly" about the EKS run before scheduled runs have passed, or any claim about AWS that no named EKS run carries (ADR 9).
- Edit the `status` branch by hand: `.github/workflows/status.yml` replaces it after every run.
