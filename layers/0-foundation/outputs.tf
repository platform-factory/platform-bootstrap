output "project_id" {
  description = "The created project id. Consumed by layer 1 via terraform_remote_state."
  value       = google_project.this.project_id
}

output "project_number" {
  description = "The created project's numeric id, needed for some IAM bindings (e.g. the GKE service agent) in later layers."
  value       = google_project.this.number
}

output "tfstate_bucket" {
  description = "Name of the GCS bucket holding this and later layers' state, once migrated. Also the value to pass as -backend-config=\"bucket=...\" for every layer's terraform init."
  value       = google_storage_bucket.tfstate.name
}

output "region" {
  description = "Region passed through to later layers so it's set in exactly one place."
  value       = var.region
}
