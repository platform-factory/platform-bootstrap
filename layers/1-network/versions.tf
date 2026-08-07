# Provider version verified 2026-08-01 against the Terraform registry
# (https://registry.terraform.io/v1/providers/hashicorp/google/versions):
# latest stable was 7.42.0, same pin as every other layer.
terraform {
  # >= 1.9 specifically because var.peer_gateway_ip's validation block
  # (variables.tf) references var.enable_vpn — cross-variable references in
  # a validation condition were added in Terraform 1.9
  # (github.com/hashicorp/terraform/blob/v1.9.0/CHANGELOG.md).
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.42"
    }
  }

  # Bucket is supplied at `terraform init` time via -backend-config, not
  # hardcoded here, so this file has no project-specific value in it. See
  # README for the exact init command.
  backend "gcs" {
    prefix = "1-network"
  }
}
