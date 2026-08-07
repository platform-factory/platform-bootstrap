output "argocd_namespace" {
  description = "Namespace Argo CD was installed into."
  value       = var.argocd_namespace
}

output "root_application_name" {
  description = "Name of the root (app-of-apps) Application."
  value       = local.root_application.metadata.name
}
