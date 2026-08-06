# Versions verified 2026-08-01:
# - google:     registry.terraform.io/v1/providers/hashicorp/google/versions
#               → latest stable 7.42.0. Same pin as every other layer;
#               needed here only for google_client_config (a short-lived
#               access token to authenticate the kubernetes/helm providers).
# - helm:       registry.terraform.io/v1/providers/hashicorp/helm/versions
#               → latest stable 3.2.0. NOTE: helm provider v3 is a breaking
#               change from v2 — provider "helm" { kubernetes { ... } } as a
#               block is gone; it's now `kubernetes = { ... }` as a nested
#               object (see providers.tf). Verified against the provider's
#               own docs (terraform-provider-helm v3.2.0 tag), not memory.
# - kubernetes: registry.terraform.io/v1/providers/hashicorp/kubernetes/versions
#               → latest stable 3.2.1. Unlike helm, the kubernetes provider's
#               own config block stayed flat attributes across 2.x → 3.x.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.42"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }

  backend "gcs" {
    prefix = "2-argocd"
  }
}
