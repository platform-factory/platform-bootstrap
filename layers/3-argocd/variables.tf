variable "project_id" {
  description = "Same project id set in 0-foundation's terraform.tfvars. Used only to locate 2-cluster's state bucket (see locals.tf) — same reason every layer above foundation takes it. Everything else is read from .outputs."
  type        = string
  default     = "platform-factory-ref"
}

variable "argocd_namespace" {
  description = "Namespace to install Argo CD into."
  type        = string
  default     = "argocd"
}

variable "root_app_repo_url" {
  description = "Git repo the Argo CD root (app-of-apps) Application watches."
  type        = string
  default     = "https://github.com/platform-factory/platform-config"
}

variable "root_app_path" {
  description = "Path within root_app_repo_url the root Application watches."
  type        = string
  default     = "."
}

variable "root_app_target_revision" {
  description = "Branch/tag the root Application tracks."
  type        = string
  default     = "main"
}

variable "root_app_automated_sync" {
  description = "Whether the root Application auto-syncs. False for now: platform-config is still an empty scaffold, so there's nothing worth auto-syncing yet and no reason to give Argo CD write access to the cluster unattended. Flip to true once platform-config has real manifests and M2 needs the paved road to actually apply on push."
  type        = bool
  default     = false
}
