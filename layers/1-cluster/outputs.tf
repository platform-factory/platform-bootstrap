# project_id and region are passed through from foundation (not just this
# layer's own facts) so that 2-argocd only ever has to read ONE remote
# state — this layer's — instead of reaching back to foundation's directly.
# Each layer depends on its immediate predecessor only.
output "project_id" {
  description = "Passed through from 0-foundation."
  value       = data.terraform_remote_state.foundation.outputs.project_id
}

output "region" {
  description = "Passed through from 0-foundation."
  value       = data.terraform_remote_state.foundation.outputs.region
}

output "cluster_name" {
  description = "GKE cluster name."
  value       = google_container_cluster.primary.name
}

output "cluster_location" {
  description = "GKE cluster location (the zone, for this zonal cluster)."
  value       = google_container_cluster.primary.location
}

output "cluster_endpoint" {
  description = "GKE cluster API server endpoint. Consumed by 2-argocd to configure the kubernetes/helm providers."
  value       = google_container_cluster.primary.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate. Consumed by 2-argocd to configure the kubernetes/helm providers."
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "network_name" {
  description = "VPC name."
  value       = google_compute_network.vpc.name
}

output "subnet_name" {
  description = "Subnet name."
  value       = google_compute_subnetwork.subnet.name
}
