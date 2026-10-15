# What the bootstrap promises (ADR 10), checked on a plan against a mocked AWS
# provider: no account, no credentials, no cost.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
}

variables {
  alert_email       = "maintainer@example.com"
  validation_domain = "eks-validation.example.com"
}

# ARNs AWS assigns at apply time, fixed so the policy text is known at plan.
override_resource {
  target          = aws_iam_openid_connect_provider.github
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
}
override_resource {
  target          = aws_iam_policy.deny_all
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:policy/platform-validation-deny-all" }
}
override_resource {
  target          = aws_s3_bucket.state
  override_during = plan
  values          = { arn = "arn:aws:s3:::123456789012-aws-eks-reference-platform-tfstate" }
}
override_resource {
  target          = aws_route53_zone.validation
  override_during = plan
  values          = { arn = "arn:aws:route53:::hostedzone/Z0VALIDATION000000000" }
}
override_resource {
  target          = aws_iam_policy.guardrails
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:policy/platform-validation-guardrails" }
}
override_resource {
  target          = aws_iam_policy.boundary
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:policy/platform-validation-boundary" }
}
override_resource {
  target          = aws_iam_role.create
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:role/platform-validation-create" }
}

run "trust" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_role.create.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:heyvaldemar/aws-eks-reference-platform:environment:aws-validation"
    error_message = "the creation role trusts this repository's aws-validation environment and nothing else"
  }
  assert {
    condition     = jsondecode(aws_iam_role.sweep.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:heyvaldemar/aws-eks-reference-platform:environment:aws-sweeper"
    error_message = "the delete-only role trusts this repository's aws-sweeper environment and nothing else"
  }
  assert {
    condition     = jsondecode(aws_iam_role.create.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    error_message = "the token's audience is STS"
  }
  assert {
    condition     = aws_iam_role.create.max_session_duration <= 7200
    error_message = "a run's credentials last no longer than two hours"
  }
}

run "guardrails" {
  command = plan

  assert {
    condition     = contains(one([for st in jsondecode(aws_iam_policy.guardrails.policy).Statement : st if st.Sid == "NoLongLivedCredentials"]).Action, "iam:CreateAccessKey")
    error_message = "no workflow role may mint long-lived credentials"
  }
  assert {
    condition     = contains(one([for st in jsondecode(aws_iam_policy.guardrails.policy).Statement : st if st.Sid == "NoAccountOrBillingChanges"]).Action, "budgets:*")
    error_message = "no workflow role may touch the budgets or the kill-switch"
  }
  assert {
    condition = alltrue([for arn in [
      "arn:aws:iam::123456789012:role/platform-validation-create",
      "arn:aws:iam::123456789012:policy/platform-validation-guardrails",
      "arn:aws:iam::123456789012:policy/platform-validation-boundary",
      "arn:aws:iam::123456789012:policy/platform-validation-deny-all",
    ] : contains(one([for st in jsondecode(aws_iam_policy.guardrails.policy).Statement : st if st.Sid == "BootstrapIsNotTheirs"]).Resource, arn)])
    error_message = "a workflow role cannot change itself, its guardrails, the boundary or the kill-switch's policy"
  }
  assert {
    condition     = one([for st in jsondecode(aws_iam_policy.guardrails.policy).Statement : st if st.Sid == "EveryRoleCarriesTheBoundary"]).Condition.StringNotEquals["iam:PermissionsBoundary"] == "arn:aws:iam::123456789012:policy/platform-validation-boundary"
    error_message = "no role can be created without the permissions boundary"
  }
  assert {
    condition     = one([for st in jsondecode(aws_iam_policy.guardrails.policy).Statement : st if st.Sid == "OnlyTheRunsRoles"]).NotResource == ["arn:aws:iam::123456789012:role/reference-platform*"]
    error_message = "a workflow role may change and pass only the run's own roles"
  }
  assert {
    condition     = one([for st in jsondecode(aws_iam_policy.guardrails.policy).Statement : st if st.Sid == "OneRegion"]).Condition.StringNotEquals["aws:RequestedRegion"] == "us-east-1"
    error_message = "regional services are denied outside the one region"
  }
  assert {
    condition     = aws_iam_role_policy_attachment.create_guardrails.policy_arn == aws_iam_policy.guardrails.arn && aws_iam_role_policy_attachment.sweep_guardrails.policy_arn == aws_iam_policy.guardrails.arn
    error_message = "both workflow roles carry the guardrails"
  }
}

run "boundary" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_policy.boundary.policy).Statement[0].Effect == "Allow" && jsondecode(aws_iam_policy.boundary.policy).Statement[0].Action == "*"
    error_message = "the boundary is a ceiling with the guardrails' denies in it"
  }
  assert {
    condition     = toset([for st in jsondecode(aws_iam_policy.boundary.policy).Statement : st.Sid if st.Effect == "Deny"]) == toset([for st in jsondecode(aws_iam_policy.guardrails.policy).Statement : st.Sid])
    error_message = "a role a run creates inherits every one of the guardrails' denies"
  }
}

run "sweeper_creates_nothing" {
  command = plan

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.sweep.policy).Statement :
      alltrue([for a in flatten([s.Action]) : !can(regex(":(Create|Run|Put|Attach|Update|Modify|Start|Associate)", a)) || a == "s3:PutObject" || a == "autoscaling:UpdateAutoScalingGroup"])
    ])
    error_message = "the delete-only role may create nothing (its only writes are the run's state object and scaling a group to zero)"
  }
  assert {
    condition     = aws_iam_role_policy_attachment.sweep_read.policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "the delete-only role reads everything, so terraform destroy can plan"
  }
}

run "budgets_and_kill_switch" {
  command = plan

  assert {
    condition     = toset([for n in aws_budgets_budget.monthly.notification : n.threshold]) == toset([10, 20])
    error_message = "the maintainer is e-mailed at $10 and $20 of actual monthly cost"
  }
  assert {
    condition     = aws_budgets_budget.monthly.cost_types[0].include_credit == false
    error_message = "the budget measures usage before credits, or an account on credits never reaches a threshold"
  }
  assert {
    condition     = aws_budgets_budget_action.kill_switch.action_threshold[0].action_threshold_value == 30 && aws_budgets_budget_action.kill_switch.approval_model == "AUTOMATIC"
    error_message = "at $30 the kill-switch fires without waiting for anyone"
  }
  assert {
    condition     = aws_budgets_budget_action.kill_switch.definition[0].iam_action_definition[0].roles == toset(["platform-validation-create"])
    error_message = "the kill-switch stops the creation role, not the sweeper"
  }
  assert {
    condition     = jsondecode(aws_iam_policy.deny_all.policy).Statement[0].Effect == "Deny" && jsondecode(aws_iam_policy.deny_all.policy).Statement[0].Action == "*"
    error_message = "what the kill-switch attaches denies everything"
  }
}

run "state_bucket" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "state is versioned"
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.state.block_public_acls && aws_s3_bucket_public_access_block.state.block_public_policy && aws_s3_bucket_public_access_block.state.ignore_public_acls && aws_s3_bucket_public_access_block.state.restrict_public_buckets
    error_message = "state is never public"
  }
  assert {
    condition     = jsondecode(aws_s3_bucket_policy.state.policy).Statement[0].Condition.Bool["aws:SecureTransport"] == "false"
    error_message = "state is reached over TLS only"
  }
}

run "kill_switch_is_a_ceiling" {
  command = plan

  variables {
    kill_switch_usd = 500
  }

  expect_failures = [var.kill_switch_usd]
}
