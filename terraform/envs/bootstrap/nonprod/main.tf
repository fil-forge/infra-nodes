# Bootstrap for the non-prod account: the state bucket every other root in this
# account keeps its state in.
#
# It lives in its own root because of a chicken-and-egg problem. The bucket is
# what every node root's backend points at, so it cannot be created by an apply
# that already keeps its state there. So this root is applied by hand, once per
# account, and everything downstream of it is ordinary.
#
# There is nothing regional here. An S3 bucket name is global, and a node in a
# second region reaches this bucket across regions the way any backend does, so
# a node outside us-east-2 needs no bootstrap of its own — only a new directory
# under terraform/envs. A production account gets a sibling of this directory.

provider "aws" {
  # Where the state bucket lives. A bucket is a regional resource even though its
  # name is global, so this is the account's home region rather than a region a
  # node necessarily runs in.
  region = "us-east-2"

  # A bucket created in the wrong account is invisible until a node root fails
  # to reach it, so name the account this root belongs to and let a mismatch
  # fail at plan time instead.
  allowed_account_ids = [module.constants.nonprod_account_id]

  default_tags {
    tags = {
      Project = "forge-nodes"
    }
  }
}

module "constants" {
  source = "../../../modules/shared/constants"
}

module "tfstate" {
  source = "../../../modules/tfstate"

  # Hard-coded in every backend block in this account, so it cannot be derived
  # there the way it is here. Stated in the same shape those blocks state it,
  # and guarded by allowed_account_ids above.
  bucket_name = "${module.constants.state_bucket_name_prefix}-${module.constants.nonprod_account_id}"
}

output "state_bucket_name" {
  value = module.tfstate.bucket_name
}
