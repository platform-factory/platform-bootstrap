# Reads 0-foundation's outputs (project id, region) instead of redeclaring
# them as variables here — one source of truth for anything foundation
# already decided. var.project_id below exists only to locate this bucket;
# every other project fact comes from .outputs.
data "terraform_remote_state" "foundation" {
  backend = "gcs"

  config = {
    bucket = local.tfstate_bucket
    prefix = "0-foundation"
  }
}

provider "google" {
  project = data.terraform_remote_state.foundation.outputs.project_id
  region  = data.terraform_remote_state.foundation.outputs.region
}
