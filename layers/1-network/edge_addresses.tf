# Reserved addresses and the proxy-only subnet for the two Gateways
# (M3b, ADR-0021 §4). The Gateways, created by platform-config's `edge`
# Application, name these in `addresses: [{type: NamedAddress, value: <name>}]`;
# the names are outputs below so they are copied, not retyped.
#
# Reserved here rather than left to the Gateway controller because the
# wildcard DNS records (dns.tf) point at them, and DNS must not change when the
# cluster, and with it the Gateways, is rebuilt.

# External Gateway (gke-l7-global-external-managed): a global static IPv4.
resource "google_compute_global_address" "edge_external" {
  name         = "edge-external"
  description  = "Static IP of the external Gateway (ADR-0021 §4). Referenced by NamedAddress."
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
}

# Internal Gateway (gke-l7-rilb): a regional internal IP out of the cluster
# subnet, so the tailnet's subnet router (private_ranges) already routes to
# it. Address left to GCP to choose from the subnet; it is stable once
# reserved, and the private-zone record follows it.
resource "google_compute_address" "edge_internal" {
  name         = "edge-internal"
  description  = "Static internal IP of the internal Gateway (ADR-0021 §4). Referenced by NamedAddress."
  address_type = "INTERNAL"
  region       = data.terraform_remote_state.foundation.outputs.region
  subnetwork   = google_compute_subnetwork.subnet.id
}

# The regional internal Application Load Balancer runs its Envoy proxies in
# this subnet. GKE's "Deploying Gateways" page (read 2026-10-27) says the
# subnet is required for the regional GatewayClasses and that it is created
# by hand, not by the controller. The global external class needs none.
# Exactly one ACTIVE proxy-only subnet is allowed per region per VPC.
resource "google_compute_subnetwork" "proxy_only" {
  name          = "${var.network_name}-proxy-only"
  network       = google_compute_network.vpc.id
  region        = data.terraform_remote_state.foundation.outputs.region
  ip_cidr_range = var.proxy_only_cidr
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# NOT in ADR-0021 §12, added because an NEG-backed load balancer cannot work
# without it: the existing allow_internal rule admits only the subnet, pod and
# Service ranges, so neither the internal Gateway's proxies (proxy-only
# range) nor either Gateway's health checks (Google's documented check ranges
# 35.191.0.0/16 and 130.211.0.0/22) can reach a pod. GKE's pages read on
# 2026-10-27 are silent on whether the Gateway controller adds these itself
# [I], so this states them; a duplicate allow is harmless. TCP only, ingress
# only. Delete this resource if the first Gateway proves the controller makes
# its own.
resource "google_compute_firewall" "allow_lb_to_pods" {
  name        = "${var.network_name}-allow-lb"
  description = "Edge load balancers (proxy-only subnet and Google health checks) to backends."
  network     = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
  }

  source_ranges = [
    var.proxy_only_cidr,
    "35.191.0.0/16",
    "130.211.0.0/22",
  ]
}
