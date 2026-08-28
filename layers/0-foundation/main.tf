# Derived exactly once here; layers 1 and 2 recompute the same formula from
# the same var.project_id to find this bucket via terraform_remote_state
# (they're independent state files — there's no way to share a local across
# a state boundary without a module, and a module wrapping one string isn't
# worth the indirection). If this formula ever changes, it has to change in
# all three layers' locals.tf.
locals {
  tfstate_bucket = "${var.project_id}-tfstate"
}

resource "google_project" "this" {
  project_id      = var.project_id
  name            = var.project_display_name
  billing_account = var.billing_account
  org_id          = var.org_id
  folder_id       = var.folder_id

  # Provider default is "PREVENT" (blocks terraform destroy from deleting the
  # project). This is a throwaway reference-build project meant to be torn
  # down and rebuilt across sessions (see README "teardown" section), so we
  # opt out of that safety rail deliberately.
  deletion_policy = "DELETE"
}

# Exactly the APIs this repo's layers need. Nothing for Argo CD itself
# (3-argocd talks to the cluster's Kubernetes API, not a GCP API).
locals {
  services = [
    "compute.googleapis.com",              # VPC, subnets, firewall rules, VPN, NAT (1-network, 2-cluster)
    "container.googleapis.com",            # GKE (2-cluster)
    "iam.googleapis.com",                  # workload identity bindings (2-cluster)
    "iamcredentials.googleapis.com",       # short-lived tokens for workload identity / gcloud auth
    "cloudresourcemanager.googleapis.com", # project-level IAM used by the above
    "serviceusage.googleapis.com",         # lets Terraform itself manage enabled services
    "storage.googleapis.com",              # the state bucket below, and GCS generally
    "artifactregistry.googleapis.com",     # the remote-repo image plane below (registry.tf) — ADR-0010

    # Added 2026-08-13, after discovering the cluster had been discarding
    # every log it produced since it was created. GKE is configured with
    # loggingService = logging.googleapis.com/kubernetes and SYSTEM_COMPONENTS
    # + WORKLOADS enabled, and the node SA holds logging.logWriter via
    # container.defaultNodeServiceAccount (iam.tf) — but with the API off at
    # the project level the writes go nowhere, silently. Nothing errors; the
    # logs simply do not exist.
    #
    # Why this wasn't caught: creating the cluster auto-enables a pile of
    # APIs as dependencies of container.googleapis.com (monitoring, autoscaling,
    # gkebackup, telemetry, ...), and monitoring.googleapis.com is among them
    # — so metrics worked and it looked like observability was fine.
    # logging.googleapis.com is NOT auto-enabled, which is the whole trap:
    # the half that got enabled for free hid the half that didn't.
    #
    # monitoring is listed explicitly even though GKE turns it on anyway.
    # An API this platform depends on should be declared by the layer that
    # owns dependencies, not inherited as a side effect of creating a cluster
    # — otherwise a rebuild's observability rests on undocumented GKE
    # behavior. Same "assume nothing exists" logic as the rest of this list.
    "logging.googleapis.com",    # cluster + NAT logs; the C-23 egress evidence path
    "monitoring.googleapis.com", # GKE metrics + managed Prometheus (auto-enabled by GKE; pinned here on purpose)
  ]
}

resource "google_project_service" "this" {
  for_each = toset(local.services)

  project = google_project.this.project_id
  service = each.value

  # Deliberately false: destroying this layer (which we don't expect to do
  # often — see README) must not disable APIs out from under a still-running
  # cluster or a partial teardown. Services are free to have enabled; there's
  # no cost reason to auto-disable them.
  disable_on_destroy = false
}

# State bucket for every later layer. Created here (not by hand) so the
# bucket is itself reproducible, but it lives in the layer that's cheap to
# keep — tearing down 2-cluster (and 3-argocd with it) never touches this.
# 1-network also persists (see its README section) but that's a design
# choice about the network, not a property of this bucket.
resource "google_storage_bucket" "tfstate" {
  name     = local.tfstate_bucket
  project  = google_project.this.project_id
  location = var.region

  # Terraform state history is the whole point of versioning here — it's the
  # only way to recover from a bad state write.
  versioning {
    enabled = true
  }

  # Uniform bucket-level access instead of per-object ACLs: this bucket only
  # ever holds Terraform state, and IAM-only access is simpler to reason
  # about and audit than mixed ACL/IAM.
  uniform_bucket_level_access = true

  depends_on = [google_project_service.this]
}
