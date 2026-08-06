# This layer reads 1-network's state only — not foundation's directly.
# 1-network already passed project_id/region through from foundation, so
# each layer here depends on just its immediate predecessor, not the whole
# chain.
data "terraform_remote_state" "network" {
  backend = "gcs"

  config = {
    bucket = local.tfstate_bucket
    prefix = "1-network"
  }
}

provider "google" {
  project = data.terraform_remote_state.network.outputs.project_id
  region  = data.terraform_remote_state.network.outputs.region
}
