# The WAF for external routes (M3b, ADR-0021 §7): one Cloud Armor policy,
# preconfigured SQL-injection rule returns 403, default allow. The route chart
# attaches it per external route through a rendered GCPBackendPolicy
# (securityPolicy: edge-external); internal routes get none.
resource "google_compute_security_policy" "edge_external" {
  name        = "edge-external"
  description = "WAF for the external Gateway's routes (ADR-0021 §7)."
  type        = "CLOUD_ARMOR"

  rule {
    action      = "deny(403)"
    priority    = 1000
    description = "Preconfigured WAF: SQL injection."

    match {
      expr {
        # evaluatePreconfiguredExpr applies the whole sqli-v33-stable rule
        # set, the form Google's examples use for "block SQLi". A narrower
        # sensitivity (evaluatePreconfiguredWaf) is a tuning choice for
        # false positives, made when one appears. [I]
        expression = "evaluatePreconfiguredExpr('sqli-v33-stable')"
      }
    }
  }

  # The default rule, priority 2147483647, is required by the API.
  rule {
    action      = "allow"
    priority    = 2147483647
    description = "Default rule: allow."

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}
