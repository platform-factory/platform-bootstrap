# Cloud NAT exists because nodes are private (private_cluster_config in
# gke.tf) and still need outbound internet. As of ADR-0010, image pulls no
# longer need it — they ride Artifact Registry remote repos over Private
# Google Access instead (0-foundation/registry.tf), which never leaves
# Google's network. NAT's one remaining consumer is Argo CD's git traffic
# to github.com (3-argocd, pulling platform-config) — a single pinhole that
# M3's FQDN-based egress work will formalize (restrict to exactly that
# destination) rather than eliminate.
#
# Lives in THIS layer, not 1-network, on purpose: it serves nodes
# specifically, so it should be created and destroyed on the same schedule
# they are, not persist with the network. Its own router (not 1-network's
# VPN router) because NAT and VPN are unrelated concerns that happen to
# both need a Cloud Router — sharing one would tie this layer's teardown to
# 1-network's VPN router, which is exactly the coupling the four-layer
# split exists to avoid.
resource "google_compute_router" "nat" {
  name    = "${var.cluster_name}-nat-router"
  network = data.terraform_remote_state.network.outputs.network_name
  region  = data.terraform_remote_state.network.outputs.region
}

resource "google_compute_router_nat" "this" {
  name   = "${var.cluster_name}-nat"
  router = google_compute_router.nat.name
  region = data.terraform_remote_state.network.outputs.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
