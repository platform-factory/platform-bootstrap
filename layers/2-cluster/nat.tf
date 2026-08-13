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

  # ALL (= translations + errors), not ERRORS_ONLY, and the reason is
  # C-23. Errors-only logs a connection that FAILED; it says nothing about
  # one that succeeded — so a node quietly pulling from a public registry,
  # the exact thing ADR-0010 claims no longer happens, would produce no log
  # line at all. Translation logging is what makes the claim falsifiable.
  #
  # NAT logs are a precise instrument here, not a noisy one, because a
  # Public NAT gateway "never performs NAT for traffic sent to the select
  # external IP addresses for Google APIs and services" (Cloud NAT product-
  # interactions docs, verified 2026-08-11) — Artifact Registry pulls ride
  # Private Google Access and bypass this gateway entirely. So NAT sees
  # only real internet egress, and on this cluster that should be Argo CD's
  # git traffic to GitHub and nothing else. Any other destination in these
  # logs is a C-23 violation, by construction.
  #
  # Kept on past the measurement: an egress audit trail is what a corp
  # environment would have (ADR-0009), and M3's FQDN egress work needs to
  # see this traffic before it can restrict it.
  log_config {
    enable = true
    filter = "ALL"
  }
}
