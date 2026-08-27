# One FilOne Appliance node: a VM, the two disks that outlive it, an address
# that outlives both, and the DNS pointing at that address.
#
# The design goal the resource layout serves is that the instance is disposable.
# Everything that cannot be rebuilt from this repository — the node's identity
# keys, its Postgres databases, its issued certificates, its Elastic IP — lives
# on a resource with prevent_destroy. Replacing the VM is an ordinary operation.

locals {
  piri_hostname  = "piri.${var.hostname_suffix}"
  ingot_hostname = "ingot.${var.hostname_suffix}"
}

# Ubuntu Server LTS for arm64, published by Canonical (099720109477). Looked up
# rather than pinned: a replaced instance rebuilds from this repository and
# holds no state, so it should come back on a patched image. Both gp2 and gp3
# image families match the filter, and most_recent picks whichever Canonical
# published last.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# The account's default VPC. A node is one instance with one public address and
# no internal services to isolate, so a VPC of its own would add a NAT gateway's
# worth of cost and three more resources to reason about for no boundary that
# the security group does not already draw.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "node" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = var.availability_zone
  default_for_az    = true
}

data "aws_route53_zone" "this" {
  name         = "${var.zone_name}."
  private_zone = false
}

# 80 and 443 in, nothing else. There is no SSH rule because there is no SSH: the
# only way onto the box is SSM Session Manager, which needs no inbound rule at
# all — the agent dials out. Port 80 is not redundant with 443; Caddy needs it
# for the HTTP-01 ACME challenge.
resource "aws_security_group" "node" {
  name        = "filone-node-${var.node_name}"
  description = "FilOne Appliance node ${var.node_name}: public HTTP and HTTPS in, everything out"
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "filone-node-${var.node_name}" }
}

resource "aws_vpc_security_group_ingress_rule" "http_ipv4" {
  security_group_id = aws_security_group.node.id
  description       = "ACME HTTP-01 challenge and the redirect to HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "https_ipv4" {
  security_group_id = aws_security_group.node.id
  description       = "Piri and Ingot, fronted by Caddy"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# Image pulls, chain RPC, ACME, the central OpenBao, Grafana Cloud and the SSM
# endpoints all leave the box, and the node initiates every one of them.
resource "aws_vpc_security_group_egress_rule" "all_ipv4" {
  security_group_id = aws_security_group.node.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# The instance profile grants Session Manager and nothing else. A node's
# authority over Forge comes from the token in its OpenBao, not from its
# position in an AWS account, so there is nothing to escalate into if the box
# is taken.
resource "aws_iam_role" "node" {
  name = "filone-node-${var.node_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# AmazonSSMManagedInstanceCore grants more than sessions: it includes
# ssm:GetParameter on every parameter in the account, and infra-central's dev
# stage keeps its secrets in Parameter Store under /forge-central/dev/*.
# Session Manager itself never reads parameters, so the deny costs nothing.
resource "aws_iam_role_policy" "deny_parameter_reads" {
  name = "deny-parameter-reads"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DenyParameterReads"
      Effect   = "Deny"
      Action   = "ssm:GetParameter*"
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "filone-node-${var.node_name}"
  role = aws_iam_role.node.name
}

# Postgres, the OpenBao raft store, Caddy's certificates and the rendered state
# the deploy scripts keep. Losing this volume loses the node's identity and
# means re-onboarding at central, which is why it is a volume rather than a
# directory on the root filesystem.
resource "aws_ebs_volume" "control" {
  availability_zone = var.availability_zone
  size              = var.control_volume_size
  type              = "gp3"
  encrypted         = true

  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "filone-node-${var.node_name}-control" }
}

# Piri's blobs and Ingot's spool and LSM segments. Losing this loses stored
# data, which is a customer-visible failure rather than an identity one, and it
# is the volume that grows.
resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "filone-node-${var.node_name}-data" }
}

resource "aws_instance" "node" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.node.id
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  # A burstable instance that runs out of credits is throttled to a fraction of
  # a core, and a node throttled during its challenge window misses a proof. Pay
  # for the overage instead.
  credit_specification {
    cpu_credits = "unlimited"
  }

  # IMDSv2 only, and a hop limit of 1. The hop limit is what stops a container
  # from reaching the metadata service through Docker's bridge: the SSM agent
  # runs on the host and is unaffected, while a compromised Piri or Ingot cannot
  # read the instance's credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/files/bootstrap.sh.tftpl", {
    node_name         = var.node_name
    control_volume_id = aws_ebs_volume.control.id
    data_volume_id    = aws_ebs_volume.data.id
    repository_url    = var.repository_url
  })

  # Bootstrap only ever runs once, so an edit to it reaches the node by
  # replacing the instance. That is the intended cost: the VM holds no state,
  # and a box whose bootstrap no longer matches the file that describes it is
  # worse than a few minutes of downtime.
  user_data_replace_on_change = true

  # Canonical publishes a new image every few weeks, and without this every one
  # of them would make the next plan propose replacing a healthy node. A fresh
  # instance still launches on the newest image, because the lookup runs at
  # create time; taking a newer one on an existing node is a deliberate
  # `tofu taint`, not a side effect of running plan on a Tuesday.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name        = "filone-node-${var.node_name}"
    RegionLabel = var.region_label
  }
}

# The node's address, and the reason it is a separate resource: the seal token
# that lets this node unseal its OpenBao is bound to this IP, and the DNS both
# hostnames resolve to points here. Releasing it means minting a new token and
# waiting out DNS, so it survives an instance replacement and carries
# prevent_destroy against an accidental one.
resource "aws_eip" "node" {
  domain = "vpc"

  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "filone-node-${var.node_name}" }
}

resource "aws_eip_association" "node" {
  instance_id   = aws_instance.node.id
  allocation_id = aws_eip.node.id
}

# skip_destroy: on an instance replacement AWS detaches these volumes as the
# instance terminates. Asking the API to detach them first races that shutdown
# and hangs until it times out, so the attachment is dropped from state instead
# and recreated against the new instance.
resource "aws_volume_attachment" "control" {
  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.control.id
  instance_id  = aws_instance.node.id
  skip_destroy = true
}

resource "aws_volume_attachment" "data" {
  device_name  = "/dev/sdg"
  volume_id    = aws_ebs_volume.data.id
  instance_id  = aws_instance.node.id
  skip_destroy = true
}

# Both hostnames point at the Elastic IP rather than the instance, so a replaced
# instance needs no DNS change and no propagation wait.
resource "aws_route53_record" "piri" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.piri_hostname
  type    = "A"
  ttl     = 300
  records = [aws_eip.node.public_ip]
}

resource "aws_route53_record" "ingot" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.ingot_hostname
  type    = "A"
  ttl     = 300
  records = [aws_eip.node.public_ip]
}
