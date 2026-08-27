# This layer reads 2-cluster's state only — not 1-network's or foundation's
# directly. 2-cluster already passed project_id/region through (which it in
# turn got from 1-network, which got them from foundation), so each layer
# here depends on just its immediate predecessor, not the whole chain.
data "terraform_remote_state" "cluster" {
  backend = "gcs"

  config = {
    bucket = local.tfstate_bucket
    prefix = "2-cluster"
  }
}

provider "google" {
  project = data.terraform_remote_state.cluster.outputs.project_id
  region  = data.terraform_remote_state.cluster.outputs.region
}

# Short-lived access token for the current `gcloud auth` identity — this is
# what lets the kubernetes/helm providers below authenticate to the GKE
# cluster without a static credential sitting in state or a tfvars file.
data "google_client_config" "default" {}

# Reaches the control plane by its DNS-based endpoint, not its IP. Two
# consequences, both deliberate:
#
#   - No cluster_ca_certificate. *.gke.goog presents a publicly trusted
#     certificate rather than the cluster's own CA, so the system trust
#     store verifies it. Passing the cluster CA here would fail TLS.
#   - No dependency on master_authorized_networks. That allowlist gated the
#     IP endpoint and broke this layer twice when a residential DHCP lease
#     turned over (2026-08-13, 2026-08-18); the DNS endpoint is gated by IAM
#     instead, so where the operator is sitting stops being load-bearing.
#
# Authorization is unchanged — the same short-lived access token below is
# still what the API server checks. Only the address and the network
# precondition changed.
provider "kubernetes" {
  host  = "https://${data.terraform_remote_state.cluster.outputs.cluster_dns_endpoint}"
  token = data.google_client_config.default.access_token
}

# helm provider v3: kubernetes config is a nested object attribute, not a
# block — see the note in versions.tf. Same two values as the kubernetes
# provider above, just a different shape because it's a different provider.
provider "helm" {
  kubernetes = {
    host  = "https://${data.terraform_remote_state.cluster.outputs.cluster_dns_endpoint}"
    token = data.google_client_config.default.access_token
  }
}
