variable "project_id" {
  description = "GCP project id to create. Project ids are globally unique across all of GCP, so the default below may already be taken by someone else — override it in terraform.tfvars if so."
  type        = string
  default     = "platform-factory-ref"
}

variable "project_display_name" {
  description = "Human-readable project name shown in the GCP Console."
  type        = string
  default     = "Platform Factory"
}

variable "billing_account" {
  description = "Billing account id to link the project to (format XXXXXX-XXXXXX-XXXXXX). Not committed anywhere — set it in the gitignored terraform.tfvars."
  type        = string
  sensitive   = true
}

variable "org_id" {
  description = "GCP organization id to create the project under. Leave null for a project created directly under a personal (non-org) account, which is the expected setup for this reference build."
  type        = string
  default     = null
}

variable "folder_id" {
  description = "GCP folder id to create the project under. Mutually exclusive with org_id; leave null alongside org_id for a personal (non-org) account."
  type        = string
  default     = null
}

variable "region" {
  description = "Default region for regional resources created in this and later layers (the state bucket here; the VPC subnet and VPN gear in 1-network; the GKE cluster in 2-cluster)."
  type        = string
  default     = "us-central1"
}
