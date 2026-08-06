# project_id and region are passed through from foundation (not just this
# layer's own facts) so that 2-cluster only ever has to read ONE remote
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

output "network_name" {
  description = "VPC name. Consumed by 2-cluster's google_container_cluster."
  value       = google_compute_network.vpc.name
}

output "subnet_name" {
  description = "Subnet name. Consumed by 2-cluster's google_container_cluster."
  value       = google_compute_subnetwork.subnet.name
}

output "pods_range_name" {
  description = "Secondary range name for pod IPs. Consumed by 2-cluster's ip_allocation_policy."
  value       = "pods"
}

output "services_range_name" {
  description = "Secondary range name for Service IPs. Consumed by 2-cluster's ip_allocation_policy."
  value       = "services"
}

output "vpn_gateway_ips" {
  description = "Google-side public IPs of the two HA VPN gateway interfaces, once enable_vpn = true — these are what get configured as the GCP-side peer addresses on the UniFi gateway. Empty when enable_vpn = false."
  value       = var.enable_vpn ? google_compute_ha_vpn_gateway.this[0].vpn_interfaces[*].ip_address : []
}
