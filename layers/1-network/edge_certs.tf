# Certificates for the external Gateway (M3b, ADR-0021 §6): one DNS
# authorization, one Google-managed wildcard certificate, one certificate map
# with one entry. The Gateway attaches the map with the annotation
# networking.gke.io/certmap: edge-external (GKE "Secure a Gateway", read
# 2026-10-27; setting tls.certificateRefs as well is an error).

# One authorization for ref.thecloudgeek.io covers the name and its wildcard.
resource "google_certificate_manager_dns_authorization" "edge" {
  name        = "edge-ref"
  description = "DNS authorization for ${var.edge_domain} and *.${var.edge_domain} (ADR-0021 §6)."
  domain      = var.edge_domain
}

# The authorization's proof is a CNAME in the public zone. It only validates
# once the zone is delegated from Cloudflare, so until that manual step the
# certificate sits in PROVISIONING. That is expected, not a fault.
resource "google_dns_record_set" "edge_acme" {
  managed_zone = google_dns_managed_zone.public.name
  name         = google_certificate_manager_dns_authorization.edge.dns_resource_record[0].name
  type         = google_certificate_manager_dns_authorization.edge.dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.edge.dns_resource_record[0].data]
}

# Wildcard only. The apex was "if cheap": it would cost nothing in the
# certificate, but the wildcard A record does not match the apex, so no
# hostname would ever use it. Left out until something serves the apex.
resource "google_certificate_manager_certificate" "edge" {
  name        = "edge-ref-wildcard"
  description = "Google-managed certificate for *.${var.edge_domain} (ADR-0021 §6)."

  managed {
    domains            = ["*.${var.edge_domain}"]
    dns_authorizations = [google_certificate_manager_dns_authorization.edge.id]
  }
}

resource "google_certificate_manager_certificate_map" "edge_external" {
  name        = "edge-external"
  description = "Certificate map attached to the external Gateway by annotation (ADR-0021 §4, §6)."
}

resource "google_certificate_manager_certificate_map_entry" "edge_external" {
  name         = "edge-external-wildcard"
  description  = "The one entry: *.${var.edge_domain}."
  map          = google_certificate_manager_certificate_map.edge_external.name
  certificates = [google_certificate_manager_certificate.edge.id]
  hostname     = "*.${var.edge_domain}"
}
