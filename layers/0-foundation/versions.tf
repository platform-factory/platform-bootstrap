# Provider version verified 2026-08-01 against the Terraform registry
# (https://registry.terraform.io/v1/providers/hashicorp/google/versions):
# latest stable was 7.42.0. Pinned to that minor as a floor so this layer
# never silently picks up an untested major version. Same pin used in every
# layer — one version to reason about, not three.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.42"
    }
  }

  # No backend block yet: this layer starts on local state because it is the
  # thing that CREATES the GCS bucket every other layer's state lives in —
  # it can't depend on a bucket it hasn't made yet. See backend.tf and
  # README.md for the one-time switch to GCS once that bucket exists.
}
