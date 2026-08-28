# A dedicated least-privilege node service account instead of the default
# Compute Engine service account. Two independent problems converge on the
# same fix:
#   - Private nodes (2-cluster) pulling from the ADR-0010 Artifact Registry
#     remote repos need artifactregistry.reader; the default SA doesn't
#     have it.
#   - This project is created under a Google Workspace org (var.org_id).
#     Orgs created on or after 2024-05-03 enforce the
#     iam.automaticIamGrantsForDefaultServiceAccounts organization policy
#     constraint by default, which stops the default Compute Engine SA from
#     automatically getting any project role at all — so on this org, that
#     SA can have NO permissions, and nodes fail logging, monitoring, and
#     image pulls on first boot regardless of the Artifact Registry
#     question above.
#
# Lives in foundation, not 2-cluster: identity persists, compute is
# disposable — the same boundary rule as everything else in this repo —
# and it avoids recreating (and re-propagating IAM for) the service
# account on every teardown/rebuild cycle.
#
# Role list verified 2026-08-06 against Google's current GKE
# node-service-account guidance:
#   - docs.cloud.google.com/kubernetes-engine/security/configure-node-service-accounts
#   - docs.cloud.google.com/kubernetes-engine/docs/how-to/hardening-your-cluster
# This corrects an older, still widely-repeated pattern of granting four
# separate roles (logging.logWriter, monitoring.metricWriter,
# monitoring.viewer, stackdriver.resourceMetadata.writer). Google's CURRENT
# official Terraform example for this exact task grants exactly one
# consolidated predefined role instead:
#
#   resource "google_service_account" "default" { ... }
#   resource "google_project_iam_member" "default" {
#     role   = "roles/container.defaultNodeServiceAccount"
#     member = "serviceAccount:${google_service_account.default.email}"
#   }
#
# That same doc page's Config Connector tab (a different tool, shown as an
# alternative to the Terraform tab above, not an addition to it) grants the
# equivalent access as four roles — logging.logWriter, monitoring.metricWriter,
# monitoring.viewer, autoscaling.metricsWriter — confirming
# defaultNodeServiceAccount already bundles those four, autoscaling metrics
# included (this cluster runs the node-count autoscaler, so that coverage
# matters). Note the fourth role there is autoscaling.metricsWriter, not
# stackdriver.resourceMetadata.writer — that role does not appear anywhere
# in either current doc page and was not carried forward here.
resource "google_service_account" "gke_nodes" {
  project      = google_project.this.project_id
  account_id   = "gke-nodes"
  display_name = "GKE node identity (2-cluster) — deliberately not the default Compute Engine service account"
}

resource "google_project_iam_member" "gke_nodes_default" {
  project = google_project.this.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# ADR-0010: lets nodes pull from the remote-repo image caches in
# registry.tf. Google's own docs grant this role per-repository rather
# than project-wide (tighter scope); this binds it at the project instead
# — six separate per-repository bindings for six remotes was judged more
# indirection than this reference build's blast radius justifies, though
# per-repository is the more correct production pattern if this SA ever
# needs to NOT read one of the six.
#
# Both bindings on this page are additive (google_project_iam_member),
# never authoritative (google_project_iam_policy / google_project_iam_binding)
# — those replace the entire project policy for the role, which would
# clobber the org's own bindings and GKE's own service-agent bindings on
# this project, not just add to them.
resource "google_project_iam_member" "gke_nodes_artifact_registry" {
  project = google_project.this.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# Crossplane's package manager pulls provider packages itself — from its
# own pod, with its own identity — not through kubelet, so the node service
# account above does nothing for it. Its fetcher (crossplane-runtime
# pkg/xpkg/fetch.go, verified 2026-08-27) authenticates through
# go-containerregistry's k8schain, which includes the Google keychain: on a
# Workload Identity cluster (2-cluster) that resolves to the pod's own
# Kubernetes service account as a federated principal. This binding grants
# that principal read access to the Artifact Registry remotes, so the
# ImageConfig mirror rule in platform-config actually pulls — no pull
# secret, no Google service account, no key anywhere.
#
# The principal identifier format is Google's documented Workload Identity
# Federation for GKE form (kubernetes-engine/docs/how-to/workload-identity,
# "Authenticate to Google Cloud APIs from GKE workloads", verified
# 2026-08-27). The namespace and service account name are the Crossplane
# chart's defaults: crossplane-system / crossplane. If either changes in
# platform-config, this binding has to change with it — the coupling is the
# price of not shipping a credential.
#
# Lives in foundation for the same reason the node identity does: identity
# persists, and this survives every teardown/rebuild cycle unchanged.
resource "google_project_iam_member" "crossplane_artifact_registry" {
  project = google_project.this.project_id
  role    = "roles/artifactregistry.reader"
  member  = "principal://iam.googleapis.com/projects/${google_project.this.number}/locations/global/workloadIdentityPools/${google_project.this.project_id}.svc.id.goog/subject/ns/crossplane-system/sa/crossplane"
}
