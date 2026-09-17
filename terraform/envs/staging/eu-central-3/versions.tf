# Terraform must stop before it can write a state OpenTofu refuses to read.
terraform {
  required_version = "< 0.0.0"
}
