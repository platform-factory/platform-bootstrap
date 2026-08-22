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

# There is deliberately no cluster_endpoint output. With
# ip_endpoints_config.enabled = false (gke.tf), the provider's `endpoint`
# attribute still reports the old control-plane IP — 34.55.89.82 at the time
# of writing — but nothing answers there: curl to it times out (exit 28)
# rather than refusing, the same silent-drop behaviour the authorized-network
# allowlist used to produce. Exporting a live-looking address for a dead path
# is how a consumer ends up debugging a "network hang" that is really a
# configuration fact, so the output is removed rather than documented in
# place. Use cluster_dns_endpoint below.

# Retained but no longer consumed: 3-argocd authenticates to the DNS-based
# endpoint, which presents a publicly trusted *.gke.goog certificate, so the
# cluster's own CA is not part of that path. Kept for any future consumer
# that talks to the cluster by an in-VPC route.
output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate. Not used by 3-argocd — see the note above."
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

# The identity-gated control plane address (gke.tf's control_plane_endpoints_config).
# Not sensitive: it is a public DNS name that resolves through Google's API
# front door, and holding it grants nothing — IAM is the gate. It also needs
# no CA certificate, because *.gke.goog presents a publicly trusted cert
# rather than the cluster's own CA. That is why 3-argocd's providers set only
# host + token against this endpoint and drop cluster_ca_certificate.
output "cluster_dns_endpoint" {
  description = "DNS-based control plane endpoint. Consumed by 3-argocd to configure the kubernetes/helm providers without depending on an IP allowlist."
  value       = google_container_cluster.primary.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint
}
