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
  description = "Four ranges: the subnet's primary range, both secondary (pod/Service) ranges, and — since M2 — the Private Services Access range Cloud SQL private IPs come out of (psa.tf). Node and pod IPs become reachable through these routes; Service ClusterIPs do not, because they are virtual rather than real VPC addresses. The PSA entry is the one whose reachability does not follow from the route alone: over the tailnet it works because the subnet router SNATs to a subnet IP, and over the HA VPN it would additionally need custom-route export on the peering — see locals.tf."
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

output "gke_security_group" {
  description = "Passed through from 0-foundation. Consumed by 2-cluster's authenticator_groups_config; null until the Workspace group exists, in which case 2-cluster renders no block. Because this is a republished value rather than one 2-cluster reads from foundation directly, setting the group in foundation's tfvars is not enough on its own: this persistent layer must then be applied by hand (cycle.sh will not do it) before a cluster rebuild can see it. Skipping that middle apply leaves the cluster with no group RBAC and no error — see 2-cluster/locals.tf."

  # try() rather than a bare attribute read, and this is not defensive
  # decoration: Terraform omits null-valued outputs from state ENTIRELY, so
  # while gke_security_group is unset — the default, and the path every first
  # apply takes — foundation's state has no such key and the bare read fails
  # the whole layer with "Unsupported attribute", taking psa.tf (and therefore
  # Cloud SQL) with it. Verified empirically 2026-09-16 with this repo's own
  # Terraform 1.15.8: a module with `output "x" { value = var.null_var }` wrote
  # a state whose outputs object contained only the non-null output.
  # `terraform validate` cannot catch this — remote-state outputs are unknown
  # until apply — which is exactly why it needs saying here. 2-cluster's read
  # of THIS output (locals.tf) is wrapped the same way, for the same reason.
  value = try(data.terraform_remote_state.foundation.outputs.gke_security_group, null)
}

# --- Private Services Access (psa.tf) ---------------------------------------

output "psa_range_name" {
  description = "Name of the Private Services Access allocated range. Not consumed by 2-cluster — it is here for the operator and for any future layer that has to attach a second service producer to the same allocation, which is done by name (google_service_networking_connection.reserved_peering_ranges takes names, not CIDRs)."
  value       = google_compute_global_address.psa.name
}

output "psa_range_cidr" {
  description = "The Private Services Access allocated range as a CIDR. Cloud SQL private IPs come out of this block, so this is the range to look for when a database's address looks unfamiliar, and the range a firewall or route list has to cover to reach one."
  value       = local.psa_range_cidr
}

output "network_self_link" {
  description = "The VPC's self link — the full \"https://www.googleapis.com/compute/v1/projects/<project>/global/networks/<name>\" URL. Cloud SQL accepts this form for settings.ipConfiguration.privateNetwork, but network_path below is the shorter form Google's own Terraform sample uses and the one the Crossplane Database Composition is written against."
  value       = google_compute_network.vpc.self_link
}

output "network_path" {
  description = "Fully-qualified VPC path, \"projects/<project>/global/networks/<name>\". This is the exact string Crossplane's Database Composition needs for DatabaseInstance settings.ipConfiguration.privateNetwork. Emitted here so the value has one source of truth in Terraform even though platform-config spells it as a literal — a Composition cannot read Terraform state, so the two are kept in sync by this output being the thing that changes first if the VPC is ever renamed."
  value       = google_compute_network.vpc.id
}
