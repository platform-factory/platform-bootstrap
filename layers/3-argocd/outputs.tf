output "argocd_namespace" {
  description = "Namespace Argo CD was installed into."
  value       = var.argocd_namespace
}

output "root_application_name" {
  description = "Name of the root (app-of-apps) Application (installed by the root-app release; see argocd.tf)."
  value       = "root"
}
