# C-12's alert source (M3b, ADR-0021 §11): a Cloud Monitoring alerting policy on
# GKE container restarts, summed per namespace. The join is
# alert -> namespace -> the System label on the namespace -> the tenant file,
# which names the team and the repo. The namespace is what the alert carries:
# the metric's resource label namespace_name is grouped on, so every incident
# is opened on exactly one namespace and its resource labels say which.
#
# NO NOTIFICATION CHANNEL, on purpose. ADR-0021 §11 tests that the alert
# fires and that the join resolves with no search, not that anyone is paged;
# a channel needs an address (an email, a webhook) that is a person's, and
# nothing here may hold one. An incident without a channel is still opened and
# readable in Cloud Monitoring and through the Monitoring API
# (projects.alertPolicies, projects.alerts). Add `notification_channels` here
# the day something should be paged.
#
# USER LABELS. Policy user_labels are static key/values, so they cannot carry
# the namespace, which differs per incident; and their keys allow only
# lowercase letters, digits, underscore and dash, so the Kubernetes label
# "platform.thecloudgeek.io/system" cannot be a key. What they do carry is the
# fixed side of the join: which claim it serves and which label on the
# namespace to read next. The per-incident side (the namespace) is in the
# incident's resource labels and, as a convenience, in the documentation
# below via ${resource.label.namespace_name}. [I: the label values are this
# build's naming; ADR-0021 §11 does not specify them.]
resource "google_monitoring_alert_policy" "container_restarts" {
  display_name = "C-12: container restarts per namespace"
  combiner     = "OR"

  user_labels = {
    claim         = "c-12"
    join          = "namespace-system-label"
    spine_label   = "platform-thecloudgeek-io-system"
    spine_lookup  = "namespace-label-then-tenant-file"
    managed_by    = "platform-bootstrap-1-network"
    adr           = "0021"
    metric_source = "gke-system-metrics"
  }

  conditions {
    display_name = "Restarts in one namespace above ${var.restart_alert_threshold} in ${var.restart_alert_window_seconds}s"

    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"k8s_container\"",
        "metric.type = \"kubernetes.io/container/restart_count\"",
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = var.restart_alert_threshold
      duration        = "0s"

      aggregations {
        alignment_period     = "${var.restart_alert_window_seconds}s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields = [
          "resource.label.project_id",
          "resource.label.location",
          "resource.label.cluster_name",
          "resource.label.namespace_name",
        ]
      }

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    # Close a quiet incident after 30 minutes so a finished synthetic test
    # does not leave one open for the registered 7 days.
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    content   = <<-EOT
      Container restarts in namespace `$${resource.label.namespace_name}` (cluster `$${resource.label.cluster_name}`) exceeded the threshold.

      Join (ADR-0021 §11): read the label `platform.thecloudgeek.io/system` on that Namespace; the System's tenant file names the team and the repo.
    EOT
  }
}
