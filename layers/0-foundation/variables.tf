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

variable "gke_security_group" {
  description = <<-EOT
    Email of the umbrella Google Group used for GKE RBAC group resolution.

    The local part MUST be exactly "gke-security-groups" — that is a GKE
    requirement, not a naming convention (kubernetes-engine/docs/how-to/
    google-groups-rbac, checked 2026-09-16: "Create a group in your domain
    named gke-security-groups. The gke-security-groups name is required.").
    Team groups are nested inside it; individual users must not be members.

    Defaults to null because the group is created by a Workspace admin
    outside Terraform and may not exist yet. While null, the
    roles/container.clusterViewer binding in iam.tf creates nothing and
    2-cluster's authenticator_groups_config block renders nothing — so the
    M2 floor can be applied before the Workspace work is done, and the
    groups can be switched on later with a variable change instead of a
    code change.
  EOT
  type        = string
  default     = null

  validation {
    # Caught here rather than two layers and one full cluster build later.
    # Without this, a wrong local part applies cleanly in this layer (the
    # clusterViewer binding in iam.tf would bind to whatever group was named,
    # succeeding if it happens to exist), flows through 1-network's passthrough
    # and is only rejected by GKE during 2-cluster's cluster creation — the
    # provider's own schema description for
    # authenticator_groups_config.security_group is "Group name must be in
    # format gke-security-groups@yourdomain.com". Null must stay valid: it is
    # the deliberate pre-Workspace state described above.
    condition     = var.gke_security_group == null || can(regex("^gke-security-groups@[a-z0-9-]+(\\.[a-z0-9-]+)+$", var.gke_security_group))
    error_message = "gke_security_group must be null, or an email whose local part is exactly \"gke-security-groups\" (a GKE requirement, not a convention)."
  }
}
