# Custom-mode (not auto-mode): auto-mode pre-creates a subnet in every GCP
# region, which is more surface area than a single-cluster reference build
# needs. One subnet, in the one region we use, declared explicitly below.
#
# This layer (VPC + subnet, and the VPN connection to another network in
# vpn.tf) is the one persistent layer above foundation — see README for why:
# in a real corporate environment the network and its connections to other
# networks outlive any one cluster.
resource "google_compute_network" "vpc" {
  name                    = var.network_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.network_name}-subnet"
  network       = google_compute_network.vpc.id
  region        = data.terraform_remote_state.foundation.outputs.region
  ip_cidr_range = var.subnet_cidr

  # Corp-standard, and required regardless: 2-cluster's nodes are private
  # (private_cluster_config) and need this to reach Google APIs (container
  # registry, Cloud Logging/Monitoring, ...) without it counting as leaving
  # the network — no external IP needed for that traffic.
  private_ip_google_access = true

  # VPC-native (alias IP) clusters need their own secondary ranges for pod
  # and Service IPs — this is what makes the cluster VPC-native instead of
  # routes-based, and what 2-cluster's ip_allocation_policy points at (by
  # name, read from this layer's outputs).
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}
