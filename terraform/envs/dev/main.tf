# The dev node: one FilOne Appliance in us-east-2, paired with infra-central's
# dev stage.
#
# Applied by hand. There is no CI role in this account for this repository yet,
# and a node's apply is rare — it creates a VM and two disks and then does
# nothing until an instance type or a volume size changes.

provider "aws" {
  region = var.region

  # Credentials for another account would otherwise apply a second, quietly
  # working copy of the node there. This fails the plan instead.
  allowed_account_ids = [module.constants.nonprod_account_id]

  default_tags {
    tags = {
      Project = "forge-nodes"
      Node    = "dev"
    }
  }
}

module "constants" {
  source = "../../modules/shared/constants"
}

variable "region" {
  description = "AWS region the node runs in. Unrelated to the region label the node presents over S3."
  type        = string
  default     = "us-east-2"
}

variable "availability_zone" {
  type = string
}

variable "hostname_suffix" {
  type = string
}

variable "ingot_hostname_suffix" {
  type = string
}

variable "piri_index" {
  type = number
}

variable "region_label" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "control_volume_size" {
  type = number
}

variable "data_volume_size" {
  type = number
}

module "node" {
  source = "../../modules/node"

  node_name         = "dev"
  region_label      = var.region_label
  availability_zone = var.availability_zone

  # Piri sits in the same Route53 zone infra-central's dev stage writes into, so
  # its hostname is next to the services it talks to. Ingot answers on the
  # content domain instead, which is a zone of its own.
  zone_name       = module.constants.dev_forge_zone_name
  hostname_suffix = var.hostname_suffix
  piri_index      = var.piri_index

  ingot_zone_name       = module.constants.dev_content_zone_name
  ingot_hostname_suffix = var.ingot_hostname_suffix

  instance_type       = var.instance_type
  control_volume_size = var.control_volume_size
  data_volume_size    = var.data_volume_size
}

output "instance_id" {
  value = module.node.instance_id
}

# The address to bind the OpenBao seal token to, and the address both hostnames
# resolve to.
output "public_ip" {
  value = module.node.public_ip
}

output "piri_url" {
  value = module.node.piri_url
}

output "ingot_url" {
  value = module.node.ingot_url
}
