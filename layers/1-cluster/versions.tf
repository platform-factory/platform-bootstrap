# Provider version verified 2026-08-01 against the Terraform registry
# (https://registry.terraform.io/v1/providers/hashicorp/google/versions):
# latest stable was 7.42.0, same pin as every other layer.
terraform {
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
    prefix = "1-cluster"
  }
}
