# project_id and region are passed through from 1-network (which itself
# passed them through from foundation) so that 3-argocd only ever has to
# read ONE remote state — this layer's — instead of reaching back further.
# Each layer depends on its immediate predecessor only.
output "project_id" {
  description = "Passed through from 0-foundation via 1-network."
  value       = data.terraform_remote_state.network.outputs.project_id
}

output "region" {
  description = "Passed through from 0-foundation via 1-network."
  value       = data.terraform_remote_state.network.outputs.region
}

output "artifact_registry_base" {
  description = "Passed through from 0-foundation via 1-network. Consumed by 3-argocd to override the chart's image locations (ADR-0010)."
  value       = data.terraform_remote_state.network.outputs.artifact_registry_base
}

output "artifact_registry_repo_ids" {
  description = "Passed through from 0-foundation via 1-network. Consumed by 3-argocd to override the chart's image locations (ADR-0010)."
  value       = data.terraform_remote_state.network.outputs.artifact_registry_repo_ids
}

output "cluster_name" {
  description = "GKE cluster name."
  value       = google_container_cluster.primary.name
}

output "cluster_location" {
  description = "GKE cluster location (the region, for this regional cluster)."
  value       = google_container_cluster.primary.location
}

output "cluster_endpoint" {
  description = "GKE cluster API server endpoint. Consumed by 3-argocd to configure the kubernetes/helm providers."
  value       = google_container_cluster.primary.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate. Consumed by 3-argocd to configure the kubernetes/helm providers."
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive   = true
}
