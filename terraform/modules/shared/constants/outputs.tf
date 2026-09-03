# Values that more than one root module has to agree on.
#
# Root modules cannot share a variable, and a literal copied into several of
# them drifts. This module creates nothing, so any root can instantiate it for
# the cost of a `module` block.

output "nonprod_account_id" {
  description = "filone-sandbox, holding every non-prod node and the bootstrap workspace that feeds them. The same account as infra-central's dev stage, which is what lets a node reach that stage's OpenBao and services without any cross-account trust."
  value       = "654654381893"
}

output "prod_account_id" {
  description = "filone-production, holding production nodes and their bootstrap workspace."
  value       = "811430801166"
}

output "dev_forge_zone_name" {
  description = "Route53 hosted zone holding the dev node's Piri record, and the zone infra-central's dev stage writes its own service names into. Delegated to this account by fil-one/infrastructure, which is what makes it a zone that exists in Route53 rather than a name served by Cloudflare."
  value       = "dev.fil-forge.com"
}

output "dev_content_zone_name" {
  description = "Route53 hosted zone holding the dev node's Ingot record. Content is served from its own domain, so an appliance's S3 name and its did:web live here rather than beside the Forge services. Delegated to this account by fil-one/infrastructure."
  value       = "dev.filonecontent.com"
}

output "state_bucket_name_prefix" {
  description = "First half of the state bucket name; the account id makes up the rest, so the name says which account's state the bucket holds. Backend blocks cannot read a variable and spell the whole name out, but every root that creates or grants access to the bucket composes it from here."
  value       = "forge-nodes-tfstate"
}
