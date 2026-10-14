# Applied once, by the maintainer, with the account's own administrator
# credentials; never from CI. Its state is local on purpose: this module
# creates the bucket every other state lives in.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      "app.kubernetes.io/part-of" = "aws-eks-reference-platform"
      "managed-by"                = "terraform/bootstrap-aws"
    }
  }
}
