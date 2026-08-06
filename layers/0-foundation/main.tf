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

# Exactly the APIs layer 0 and layer 1 need. Nothing for Argo CD itself
# (layer 2 talks to the cluster's Kubernetes API, not a GCP API).
locals {
  services = [
    "compute.googleapis.com",              # VPC, subnets, firewall rules (layer 1)
    "container.googleapis.com",            # GKE (layer 1)
    "iam.googleapis.com",                  # workload identity bindings (layer 1)
    "iamcredentials.googleapis.com",       # short-lived tokens for workload identity / gcloud auth
    "cloudresourcemanager.googleapis.com", # project-level IAM used by the above
    "serviceusage.googleapis.com",         # lets Terraform itself manage enabled services
    "storage.googleapis.com",              # the state bucket below, and GCS generally
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

# State bucket for layers 1 and 2. Created here (not by hand) so the bucket
# is itself reproducible, but it lives in the layer that's cheap to keep —
# tearing down 1-cluster never touches this.
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
