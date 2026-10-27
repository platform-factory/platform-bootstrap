# DNS for the edge (M3b, ADR-0021 §5). No external-dns and no per-route DNS
# write: a route changes no DNS. Each zone holds one wildcard A record, to the
# Gateway's reserved address (edge_addresses.tf).
#
# Both zones live here, in the persistent layer, for the reason the network
# does: the public zone's name servers are pasted into Cloudflare once, by
# hand, and must not change when the cluster is torn down. Destroying 2-cluster
# or 3-argocd never touches them.

resource "google_dns_managed_zone" "public" {
  name        = "ref-public"
  dns_name    = "${var.edge_domain}."
  description = "Public zone for the reference environment (ADR-0021 §5). Delegated from Cloudflare by one manual step."
  visibility  = "public"

  # DNSSEC is OFF, deliberately. Signing the zone only protects resolvers once
  # the parent publishes a matching DS record, and the parent is Cloudflare's
  # thecloudgeek.io zone: that would be a second manual step beyond the one
  # ADR-0021 §5 declares (the NS delegation), and a wrong DS record makes the
  # whole zone fail validation, taking certificate issuance with it. Nothing
  # in M3's claims reads DNSSEC. To turn it on later: state = "on", apply, then
  # add the DS record from `gcloud dns dns-keys list` at Cloudflare, in that
  # order. [I, a judgement, not a fact about Google's product]
  dnssec_config {
    state = "off"
  }
}

resource "google_dns_managed_zone" "private" {
  name        = "ref-internal"
  dns_name    = "internal.${var.edge_domain}."
  description = "Private zone for internal routes (ADR-0021 §5), visible only inside the VPC."
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc.id
    }
  }
}

# Wildcard A records. TTL 300: short enough that moving a Gateway's address
# (it should never happen, the addresses are reserved) is not a day's wait.
# Wildcards do not match the apex, so ref.thecloudgeek.io itself has no
# address; nothing needs one (the certificate is for *.ref only, see
# edge_certs.tf).
resource "google_dns_record_set" "public_wildcard" {
  managed_zone = google_dns_managed_zone.public.name
  name         = "*.${google_dns_managed_zone.public.dns_name}"
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.edge_external.address]
}

resource "google_dns_record_set" "private_wildcard" {
  managed_zone = google_dns_managed_zone.private.name
  name         = "*.${google_dns_managed_zone.private.dns_name}"
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.edge_internal.address]
}
