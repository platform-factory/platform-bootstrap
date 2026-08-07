# Same formula 0-foundation used to name the bucket (see its main.tf),
# recomputed here for the same reason every other layer recomputes it:
# separate state file, no way to import a local across that boundary.
locals {
  tfstate_bucket = "${var.project_id}-tfstate"
}
