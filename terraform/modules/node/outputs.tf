output "instance_id" {
  description = "Target for `aws ssm start-session`; scripts/operator/ssm-session.sh reads it from here."
  value       = aws_instance.node.id
}

output "public_ip" {
  description = "The address the seal token is bound to. scripts/operator/mint-seal-token.sh needs it, and a change here invalidates the token the node holds."
  value       = aws_eip.node.public_ip
}

output "piri_url" {
  description = "Piri's public URL. Registered with sprue at onboarding and written into Piri's own config as public_url, so the three have to agree."
  value       = "https://${local.piri_hostname}"
}

output "ingot_url" {
  description = "Ingot's public URL. S3 clients address it path-style: there is no wildcard certificate for bucket subdomains."
  value       = "https://${local.ingot_hostname}"
}

output "control_volume_id" {
  value = aws_ebs_volume.control.id
}

output "data_volume_id" {
  value = aws_ebs_volume.data.id
}
