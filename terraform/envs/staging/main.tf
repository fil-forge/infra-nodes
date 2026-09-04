# DNS for the Servers.com staging appliance. This root creates no host resources.
provider "aws" {
  region              = "us-east-2"
  allowed_account_ids = [module.constants.nonprod_account_id]

  default_tags {
    tags = {
      Project = "forge-nodes"
      Node    = "staging"
    }
  }
}

module "constants" {
  source = "../../modules/shared/constants"
}

data "aws_route53_zone" "forge" {
  name         = "staging.fil-forge.com."
  private_zone = false
}

data "aws_route53_zone" "content" {
  name         = "staging.filonecontent.com."
  private_zone = false
}

locals {
  server_ip = "23.83.66.244"
}

resource "aws_route53_record" "piri" {
  zone_id = data.aws_route53_zone.forge.zone_id
  name    = "piri-0.staging.fil-forge.com"
  type    = "A"
  ttl     = 300
  records = [local.server_ip]
}

resource "aws_route53_record" "ingot" {
  zone_id = data.aws_route53_zone.content.zone_id
  name    = "s3.eu-central-3.staging.filonecontent.com"
  type    = "A"
  ttl     = 300
  records = [local.server_ip]
}
