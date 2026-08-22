# Cloud NAT: outbound internet for resources that have no external IP.
#
# MOVED HERE FROM 2-cluster ON 2026-08-20 (ADR-0011). The original placement
# was reasoned as "NAT serves nodes specifically, so it should be created and
# destroyed on the same schedule they are." That premise stopped holding when
# the jump box (jumpbox.tf) arrived: NAT now has two consumers on different
# schedules, and a persistent resource cannot depend on a disposable one. The
# jump box carries the Tailscale subnet router, and Tailscale needs *outbound*
# reachability to the coordination server to stay on the tailnet — so if NAT
# died with the cluster, so would user access to this VPC. That would put
# reachability in the disposable layer, which is precisely what this repo's
# boundary rule ("identity and reachability persist; compute is disposable")
# exists to prevent.
#
# Cost of running it continuously is small and scales per attached VM: the
# gateway is $0.0014/hr * VMs attached (up to 32, only then flattening to
# $0.044/hr) plus $0.005/hr for the external IP. Between sessions that is one
# VM — roughly $5/month all in, verified against Cloud NAT pricing 2026-08-20.
#
# NOTE for C-02: moving NAT out of 2-cluster removes its create/destroy from
# the measured rebuild path, so cycle timings after this change are not
# directly comparable to the cycle-1 baseline. See the build log.
#
# Its own Cloud Router rather than the VPN's: vpn.tf's router is count-gated
# on enable_vpn, so NAT cannot depend on it existing. They remain unrelated
# concerns that merely both need a router.
resource "google_compute_router" "nat" {
  name    = "${var.network_name}-nat-router"
  network = google_compute_network.vpc.id
  region  = data.terraform_remote_state.foundation.outputs.region
}

resource "google_compute_router_nat" "this" {
  name   = "${var.network_name}-nat"
  router = google_compute_router.nat.name
  region = data.terraform_remote_state.foundation.outputs.region

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
  # One consumer was added by the move: the jump box's Tailscale client
  # talks to Tailscale's coordination server and, when direct peer-to-peer
  # fails, its DERP relays. That is expected egress, not a C-23 violation —
  # C-23 is about *image pulls* bypassing Artifact Registry. Read these logs
  # with both consumers in mind.
  #
  # Kept on past the measurement: an egress audit trail is what a corp
  # environment would have (ADR-0009), and M3's FQDN egress work needs to
  # see this traffic before it can restrict it.
  log_config {
    enable = true
    filter = "ALL"
  }
}
