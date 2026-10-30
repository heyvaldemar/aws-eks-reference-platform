variable "region" {
  description = "The only region validation runs may create resources in."
  type        = string
  default     = "us-east-1"
}

variable "repository" {
  description = "The GitHub repository whose workflows may assume the roles, as owner/name."
  type        = string
  default     = "heyvaldemar/aws-eks-reference-platform"
}

variable "subject_repository" {
  description = <<-EOT
    The repository as GitHub writes it into the OIDC token's subject, which is
    what the roles' trust policies match. A repository created or renamed after
    15 July 2026 gets the immutable form, owner@OWNER_ID/name@REPO_ID, so a
    name given up and taken by someone else cannot match; an older one keeps
    owner/name until it opts in. Read it with
      gh api repos/OWNER/NAME/actions/oidc/customization/sub --jq .sub_claim_prefix
    and drop the leading "repo:".
  EOT
  type        = string
  default     = "heyvaldemar@10498744/aws-eks-reference-platform@1414733910"

  validation {
    condition = (
      can(regex("^[A-Za-z0-9-]+@[0-9]+/[A-Za-z0-9._-]+@[0-9]+$", var.subject_repository)) ||
      can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.subject_repository))
    )
    error_message = "subject_repository is owner@OWNER_ID/name@REPO_ID (immutable) or owner/name (legacy), as the token's subject carries it."
  }

  validation {
    condition     = replace(var.subject_repository, "/@[0-9]+/", "") == var.repository
    error_message = "subject_repository names a different repository than repository: the roles would trust a workflow the descriptions do not name."
  }
}

variable "also_create" {
  description = <<-EOT
    Other repositories whose validation workflow may assume the creation role,
    in the same environment, as owner/name => the subject GitHub writes into
    their tokens (see subject_repository; immutable form only). Each runs a
    disposable validation in this account under the same guardrails,
    permissions boundary, budget and kill-switch, and can do nothing this
    repository's own run cannot. The delete-only role stays this repository's.
  EOT
  type        = map(string)
  default = {
    "heyvaldemar/kubernetes-air-gapped-ai-agent"   = "heyvaldemar@10498744/kubernetes-air-gapped-ai-agent@1421238353"
    "heyvaldemar/kubernetes-llm-inference-gateway" = "heyvaldemar@10498744/kubernetes-llm-inference-gateway@1439207666"
  }

  validation {
    condition = alltrue([
      for name, subject in var.also_create :
      can(regex("^[A-Za-z0-9-]+@[0-9]+/[A-Za-z0-9._-]+@[0-9]+$", subject)) && replace(subject, "/@[0-9]+/", "") == name
    ])
    error_message = "each also_create entry is owner/name => owner@OWNER_ID/name@REPO_ID for that same repository."
  }
}

variable "create_environment" {
  description = "The GitHub environment the creation role trusts. The validation workflow runs in it."
  type        = string
  default     = "aws-validation"
}

variable "sweeper_environment" {
  description = "The GitHub environment the delete-only role trusts. The sweeper workflow runs in it."
  type        = string
  default     = "aws-sweeper"
}

variable "alert_email" {
  description = "Where the budget alerts and the kill-switch notice go: the maintainer's own address."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be an e-mail address."
  }
}

variable "validation_domain" {
  description = <<-EOT
    The DNS name validation runs serve under, such as eks-validation.example.com.
    This module creates its hosted zone once; delegate it once from the parent
    zone using the name_servers output, and every run issues real certificates.
  EOT
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.validation_domain))
    error_message = "validation_domain must be a DNS name such as eks-validation.example.com."
  }
}

variable "cluster_name_prefix" {
  description = "The prefix every IAM name a run creates starts with (the cluster name). The sweeper may delete IAM roles and policies with this prefix only."
  type        = string
  default     = "reference-platform"
}

variable "alert_thresholds_usd" {
  description = "Monthly actual cost at which the maintainer is e-mailed (ADR 10: $10 and $20)."
  type        = list(number)
  default     = [10, 20]
}

variable "kill_switch_usd" {
  description = "Monthly actual cost at which AWS Budgets attaches deny-all to the creation role (ADR 10: $30)."
  type        = number
  default     = 30

  validation {
    condition     = var.kill_switch_usd > 0 && var.kill_switch_usd <= 50
    error_message = "kill_switch_usd is a positive number no higher than 50: it is a ceiling for mistakes, not a budget."
  }
}
