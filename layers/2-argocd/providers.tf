# This layer reads 1-cluster's state only — not foundation's directly.
# 1-cluster already passed project_id/region through from foundation, so
# each layer here depends on just its immediate predecessor, not the whole
# chain.
data "terraform_remote_state" "cluster" {
  backend = "gcs"

  config = {
    bucket = local.tfstate_bucket
    prefix = "1-cluster"
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

provider "kubernetes" {
  host                   = "https://${data.terraform_remote_state.cluster.outputs.cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(data.terraform_remote_state.cluster.outputs.cluster_ca_certificate)
}

# helm provider v3: kubernetes config is a nested object attribute, not a
# block — see the note in versions.tf. Same three values as the kubernetes
# provider above, just a different shape because it's a different provider.
provider "helm" {
  kubernetes = {
    host                   = "https://${data.terraform_remote_state.cluster.outputs.cluster_endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(data.terraform_remote_state.cluster.outputs.cluster_ca_certificate)
  }
}
