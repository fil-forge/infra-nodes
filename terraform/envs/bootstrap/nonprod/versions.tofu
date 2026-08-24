terraform {
  required_version = ">= 1.12"

  # This root's own state, in the bucket this root creates. That circularity is
  # resolved once per account, by the bootstrap procedure in docs/RUNBOOK.md:
  # the first apply runs against a local backend and then moves its state in
  # here.
  backend "s3" {
    bucket       = "forge-nodes-tfstate-654654381893"
    key          = "bootstrap/nonprod.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
