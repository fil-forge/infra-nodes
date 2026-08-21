variable "node_name" {
  description = "Short name for this node, used in resource names, tags and the directory under nodes/ that the host scripts read. Lowercase, no spaces."
  type        = string
}

variable "hostname_suffix" {
  description = "Suffix the node's two public hostnames share, e.g. dev.forge-sandbox.fil.one. Piri answers at piri.<suffix> and Ingot at ingot.<suffix>. Stated explicitly rather than derived from zone_name, because the delegation point and the hostname shape need not match."
  type        = string
}

variable "zone_name" {
  description = "Route53 hosted zone the A records go into. Must be a zone that actually exists in Route53: fil.one itself is served by Cloudflare, so this is the delegated subdomain."
  type        = string
}

variable "availability_zone" {
  description = "The AZ the instance and both EBS volumes live in. Pinned rather than chosen at apply time: a volume cannot move between AZs, and both volumes carry prevent_destroy, so a changed AZ would leave the node unable to attach the disks holding its identity."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. ARM (Graviton) types require the arm64 AMI the module looks up, so an x86 type here fails at launch."
  type        = string
  default     = "t4g.large"
}

variable "control_volume_size" {
  description = "GB for the control-plane volume: Postgres data, the OpenBao raft store, Caddy's certificates and rendered state. This is the volume that carries the node's identity."
  type        = number
  default     = 50
}

variable "data_volume_size" {
  description = "GB for the data-plane volume: Piri's blobs and Ingot's spool and LSM segments. Grows with what the node stores; the control volume does not."
  type        = number
  default     = 500
}

variable "root_volume_size" {
  description = "GB for the root volume. Holds the OS, the container images and the git checkout, all of which are recreated from scratch on a replaced instance."
  type        = number
  default     = 30
}

variable "region_label" {
  description = "The virtual S3 region this node presents, e.g. us-east-9. Deliberately not a real AWS region. Nothing in this module uses it as an address; it is tagged onto the instance so the box says which region label it serves, and it must match Ingot's config, hilt's provider registration and the AWS_REGION clients sign with."
  type        = string
}

variable "repository_url" {
  description = "Clone URL for this repository. Public, so the node needs no git credential."
  type        = string
  default     = "https://github.com/fil-forge/infra-nodes.git"
}

variable "repository_ref" {
  description = "Branch the node tracks. The reconcile timer resets to origin/<ref> every five minutes, so this is the thing that decides what the node runs."
  type        = string
  default     = "main"
}
