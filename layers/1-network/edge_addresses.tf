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

# No firewall rule for the load balancers here. GKE's "Automatically created
# firewall rules" page [C, docs.cloud.google.com/kubernetes-engine/docs/
# concepts/firewall-rules, read 2026-10-27] lists `gkegw1-l7-<network>-<region
# or global>`, from 35.191.0.0/16, 130.211.0.0/22 and the proxy-only ranges to
# TCP 1-65535, which "The Gateway controller creates ... when the first Gateway
# resource is created". The same page says that under Shared VPC the Gateway
# rules are not deployed automatically; this VPC is not shared. The first
# Gateway reads the rule from the project. If it is missing, the rule is added
# then as a crossing ADR-0021 §12 did not declare, and C-01 counts it.
