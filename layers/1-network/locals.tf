# Same formula 0-foundation used to name the bucket in the first place
# (see its main.tf), recomputed here because this is a separate state file
# with no way to import that layer's locals directly — only its outputs,
# and we need the bucket name before we can read those.
locals {
  tfstate_bucket = "${var.project_id}-tfstate"
}
