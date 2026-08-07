# Uncomment this block AFTER the first `terraform apply` (once the state
# bucket resource below actually exists), then run:
#
#   terraform init -backend-config="bucket=<PROJECT_ID>-tfstate" -migrate-state
#
# The bucket name is left out of this file on purpose — it's derived from
# var.project_id, and Terraform backend blocks can't reference variables.
# Supplying it via -backend-config keeps this file portable across whatever
# project id an operator actually ends up with.
#
# terraform {
#   backend "gcs" {
#     prefix = "0-foundation"
#   }
# }
