# tflint with the Terraform language rules at their recommended preset and
# the AWS ruleset, which knows instance types, regions and argument values the
# provider schema alone does not.
config {
  call_module_type = "none"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.49.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
