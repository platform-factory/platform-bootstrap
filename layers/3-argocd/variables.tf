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
  description = "Whether the root Application auto-syncs (with prune and selfHeal). True as of 2026-08-13. It was false while platform-config was being scaffolded, on the reasoning that Argo CD shouldn't have unattended write access to the cluster with nothing worth syncing. Flipped for two reasons: C-02 claims the cluster rebuilds 'without manual steps' and targets zero manual interventions, which is unreachable when every rebuild ends with a human clicking Sync — the claim and this default contradicted each other, and the claim is the one describing the design. And an empty platform-config is the safest possible moment to make the change: Argo CD adopts nothing and prunes nothing today, so auto-sync behavior can be observed on an empty surface before M2 puts real manifests behind it. The gate on what reaches the cluster is platform-config's PR review, not Argo CD sitting idle."
  type        = bool
  default     = true
}
