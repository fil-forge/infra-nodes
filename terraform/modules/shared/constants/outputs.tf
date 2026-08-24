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

output "nonprod_zone_name" {
  description = "Route53 hosted zone every non-prod node writes its A records into. fil.one itself is served by Cloudflare, so this is the delegated subdomain that actually exists in Route53, and it is the same zone infra-central's non-prod stages use."
  value       = "forge-sandbox.fil.one"
}

output "state_bucket_name_prefix" {
  description = "First half of the state bucket name; the account id makes up the rest, so the name says which account's state the bucket holds. Backend blocks cannot read a variable and spell the whole name out, but every root that creates or grants access to the bucket composes it from here."
  value       = "forge-nodes-tfstate"
}
