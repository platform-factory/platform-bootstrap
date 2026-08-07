# Posture (ADR-0009 — mock a real corp environment over cost, no scale
# needed): this is a minimal corp-real baseline, not a lockdown exercise.
#
# What this deliberately does NOT do:
#   - Add a broad deny-all. Custom-mode VPCs (network.tf: auto_create_subnetworks
#     = false) already implicitly deny any ingress that isn't explicitly
#     allowed — there's no default-allow here to close off.
#   - Touch GKE's own control-plane/node firewall rules. 2-cluster's
#     google_container_cluster resource manages those itself (health checks,
#     node-to-master, ...); adding our own broad rules here risks fighting
#     or shadowing rules GKE expects to own.
#   - Restrict egress. Egress lockdown (FQDN-based policy) is deliberately
#     deferred to the M3 egress-control work, not this layer — see README.
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.network_name}-allow-internal"
  network = google_compute_network.vpc.id

  allow {
    protocol = "all"
  }

  # Subnet primary range plus both secondary (pod/Service) ranges — the
  # whole "inside this VPC" trust boundary, not just node IPs.
  source_ranges = [
    var.subnet_cidr,
    var.pods_cidr,
    var.services_cidr,
  ]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
