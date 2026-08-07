output "project_id" {
  description = "The created project id. Consumed by layer 1 via terraform_remote_state."
  value       = google_project.this.project_id
}

output "project_number" {
  description = "The created project's numeric id, needed for some IAM bindings (e.g. the GKE service agent) in later layers."
  value       = google_project.this.number
}

output "tfstate_bucket" {
  description = "Name of the GCS bucket holding this and later layers' state, once migrated. Also the value to pass as -backend-config=\"bucket=...\" for every layer's terraform init."
  value       = google_storage_bucket.tfstate.name
}

output "region" {
  description = "Region passed through to later layers so it's set in exactly one place."
  value       = var.region
}

output "artifact_registry_base" {
  description = "Base path for this project's Artifact Registry Docker repos: \"<region>-docker.pkg.dev/<project_id>\". Prepend one of artifact_registry_repo_ids and the upstream's own image path to get a pullable reference — see 3-argocd's argocd.tf for a worked example."
  value       = "${var.region}-docker.pkg.dev/${google_project.this.project_id}"
}

output "artifact_registry_repo_ids" {
  description = "Map of upstream name to its Artifact Registry remote repository id (registry.tf)."
  value = {
    docker_hub      = google_artifact_registry_repository.docker_hub.repository_id
    quay_io         = google_artifact_registry_repository.quay_io.repository_id
    ghcr_io         = google_artifact_registry_repository.ghcr_io.repository_id
    ecr_public      = google_artifact_registry_repository.ecr_public.repository_id
    registry_k8s_io = google_artifact_registry_repository.registry_k8s_io.repository_id
    xpkg_upbound_io = google_artifact_registry_repository.xpkg_upbound_io.repository_id
  }
}

output "gke_node_service_account_email" {
  description = "Email of the dedicated GKE node service account (iam.tf). Consumed by 2-cluster's node_config.service_account, via 1-network's passthrough."
  value       = google_service_account.gke_nodes.email
}
