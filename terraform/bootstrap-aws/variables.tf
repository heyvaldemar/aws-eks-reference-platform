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
