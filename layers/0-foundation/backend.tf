# Committed ENABLED: the state bucket this points at exists for every
# clone after the very first bootstrap, and an init that silently fell
# back to local state here would later produce a plan proposing to
# re-create all of live foundation — the worst kind of surprise. The one
# exception is a true from-nothing bootstrap, where the bucket doesn't
# exist yet because this very layer creates it: comment this block out
# for the first apply only, then restore it and run
#
#   terraform init -backend-config="bucket=<PROJECT_ID>-tfstate" -migrate-state
#
# (full sequence in the README runbook). The bucket name is left out of
# this file on purpose — it's derived from var.project_id, and Terraform
# backend blocks can't reference variables. Supplying it via
# -backend-config keeps this file portable across whatever project id an
# operator actually ends up with.
terraform {
  backend "gcs" {
    prefix = "0-foundation"
  }
}
