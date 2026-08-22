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

output "artifact_registry_base" {
  description = "Passed through from 0-foundation."
  value       = data.terraform_remote_state.foundation.outputs.artifact_registry_base
}

output "artifact_registry_repo_ids" {
  description = "Passed through from 0-foundation."
  value       = data.terraform_remote_state.foundation.outputs.artifact_registry_repo_ids
}

output "gke_node_service_account_email" {
  description = "Passed through from 0-foundation. Consumed by 2-cluster's node_config.service_account."
  value       = data.terraform_remote_state.foundation.outputs.gke_node_service_account_email
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

# Consumed by whatever provides operator reachability into the VPC. For a
# Tailscale subnet router this is the Connector's advertised route set; for
# the HA VPN it is what Cloud Router advertises over BGP. Same ranges either
# way — see locals.tf.
output "private_ranges" {
  description = "Subnet primary range plus both secondary (pod/Service) ranges. Node and pod IPs become reachable through these routes; Service ClusterIPs do not, because they are virtual rather than real VPC addresses — see locals.tf."
  value       = local.private_ranges
}

output "jumpbox_name" {
  description = "Jump box instance name. Used with `gcloud compute ssh --tunnel-through-iap`, which is the break-glass path in — it needs no egress, so it works even when NAT or the tailnet is broken."
  value       = google_compute_instance.jumpbox.name
}

output "jumpbox_zone" {
  description = "Jump box zone. Required by gcloud for both SSH and IAP tunnels."
  value       = google_compute_instance.jumpbox.zone
}

output "jumpbox_internal_ip" {
  description = "Jump box private address. It has no external IP by design."
  value       = google_compute_instance.jumpbox.network_interface[0].network_ip
}

# The one-time join. Deliberately emitted as a command to run rather than
# executed by the startup script: joining needs a Tailscale auth key, and
# putting one in instance metadata would write a credential into Terraform
# state and into the metadata server. Run it once over IAP; the node stays
# joined across reboots. Routes must then be approved in the Tailscale admin
# console before peers can use them.
output "jumpbox_tailscale_up_command" {
  description = "One-time command to join the jump box to the tailnet as a subnet router, to be run on the box itself after `gcloud compute ssh <jumpbox_name> --tunnel-through-iap --zone <jumpbox_zone>`."
  value       = "sudo tailscale up --advertise-routes=${join(",", local.private_ranges)} --accept-dns=false"
}
