# HA VPN to a peer network (the home/corp side — a UniFi gateway for this
# build). Every resource below is gated by var.enable_vpn via count, so with
# it false (the default) this file creates nothing and 1-network is just a
# VPC and subnet. See the README's VPN section for the operator flow and
# what the peer side needs to support (BGP).
#
# This is the standard GCP HA VPN + Cloud Router pattern: one HA VPN
# gateway (two Google-managed interfaces for redundancy) paired with one
# external ("peer") gateway representing the non-GCP side, two tunnels (one
# per HA VPN interface — a "proper HA pair", not a single tunnel), and BGP
# over each tunnel so routes propagate automatically instead of being
# hand-maintained as static routes.

resource "google_compute_ha_vpn_gateway" "this" {
  count = var.enable_vpn ? 1 : 0

  name    = "${var.network_name}-vpn-gw"
  region  = data.terraform_remote_state.foundation.outputs.region
  network = google_compute_network.vpc.id
}

resource "google_compute_external_vpn_gateway" "peer" {
  count = var.enable_vpn ? 1 : 0

  name = "${var.network_name}-peer-gw"
  # SINGLE_IP_INTERNALLY_REDUNDANT: the peer is one gateway with one public
  # IP (the UniFi box's WAN address), not a redundant pair of peer devices.
  redundancy_type = "SINGLE_IP_INTERNALLY_REDUNDANT"

  interface {
    id         = 0
    ip_address = var.peer_gateway_ip
  }
}

resource "google_compute_router" "this" {
  count = var.enable_vpn ? 1 : 0

  name    = "${var.network_name}-router"
  network = google_compute_network.vpc.id
  region  = data.terraform_remote_state.foundation.outputs.region

  bgp {
    asn = var.cloud_router_asn
  }
}

# Two tunnels — one per HA VPN gateway interface (0 and 1) — is what makes
# this a "proper HA pair" instead of a single point of failure on the
# Google side.
resource "google_compute_vpn_tunnel" "tunnel" {
  count = var.enable_vpn ? 2 : 0

  name   = "${var.network_name}-tunnel-${count.index}"
  region = data.terraform_remote_state.foundation.outputs.region

  vpn_gateway                     = google_compute_ha_vpn_gateway.this[0].id
  vpn_gateway_interface           = count.index
  peer_external_gateway           = google_compute_external_vpn_gateway.peer[0].id
  peer_external_gateway_interface = 0
  shared_secret                   = var.vpn_shared_secret
  router                          = google_compute_router.this[0].id
  ike_version                     = 2
}

# Link-local /30s for the BGP session on each tunnel — 169.254.0.0/30 and
# 169.254.1.0/30, the standard non-overlapping pair GCP's own HA VPN
# examples use when there's no reason to pick anything else.
resource "google_compute_router_interface" "tunnel" {
  count = var.enable_vpn ? 2 : 0

  name       = "${var.network_name}-router-if-${count.index}"
  router     = google_compute_router.this[0].name
  region     = data.terraform_remote_state.foundation.outputs.region
  ip_range   = "169.254.${count.index}.1/30"
  vpn_tunnel = google_compute_vpn_tunnel.tunnel[count.index].name
}

resource "google_compute_router_peer" "tunnel" {
  count = var.enable_vpn ? 2 : 0

  name            = "${var.network_name}-bgp-peer-${count.index}"
  router          = google_compute_router.this[0].name
  region          = data.terraform_remote_state.foundation.outputs.region
  interface       = google_compute_router_interface.tunnel[count.index].name
  peer_ip_address = "169.254.${count.index}.2"
  peer_asn        = var.peer_asn

  # CUSTOM instead of the ALL_SUBNETS default group: advertise exactly the
  # ranges in local.private_ranges, not "every subnet in this VPC"
  # (there's only one today, but this stays correct if that changes).
  advertise_mode = "CUSTOM"

  dynamic "advertised_ip_ranges" {
    for_each = local.private_ranges
    content {
      range = advertised_ip_ranges.value
    }
  }
}
