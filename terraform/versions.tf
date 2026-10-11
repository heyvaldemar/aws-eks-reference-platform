terraform {
  # 1.10 for S3-native state locking (use_lockfile) and mock providers in
  # `terraform test`.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }

  # State is local by default so `make eks-up` works on a fresh account with
  # nothing created beforehand. For anything shared, use an S3 backend with
  # native locking; see docs/runbooks/upgrade.md:
  #
  #   terraform init -backend-config="bucket=<state bucket>" \
  #     -backend-config="key=aws-eks-reference-platform.tfstate" \
  #     -backend-config="region=<region>" -backend-config="use_lockfile=true"
}

provider "aws" {
  region = var.region

  # Every resource carries these, which is what lets a cost report or a
  # residue search find everything one run created.
  default_tags {
    tags = merge(var.tags, {
      "platform.heyvaldemar.com/project" = "aws-eks-reference-platform"
      "platform.heyvaldemar.com/cluster" = var.cluster_name
      "run-id"                           = var.run_id
      "managed-by"                       = "terraform"
    })
  }
}
