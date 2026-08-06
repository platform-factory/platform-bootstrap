# The root (app-of-apps) Application, rendered through the chart's
# extraObjects value rather than a separate kubernetes_manifest resource.
#
# Why: a kubernetes_manifest resource for an Application CRD is validated
# against the live API server's schema at PLAN time. On a genuinely first
# apply of this layer, that CRD doesn't exist until THIS helm_release
# installs it — so a separate kubernetes_manifest would fail plan with "no
# matches for kind Application" before the chart that creates the CRD has
# ever run. extraObjects sidesteps this because Helm installs a chart's
# crds/ directory before its templates within the same release, so the CRD
# and this object land in the same `helm install`, in working order.
locals {
  root_application = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root"
      namespace = var.argocd_namespace
    }
    spec = merge(
      {
        project = "default"
        source = {
          repoURL        = var.root_app_repo_url
          path           = var.root_app_path
          targetRevision = var.root_app_target_revision
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "default"
        }
      },
      # syncPolicy.automated is entirely OMITTED (not just empty) when
      # disabled, matching Argo CD's own default of manual-sync-if-absent.
      var.root_app_automated_sync ? {
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
        }
      } : {}
    )
  }
}

resource "helm_release" "argocd" {
  name       = "argo-cd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  # Chart version verified 2026-08-01 via Artifact Hub
  # (artifacthub.io/api/v1/packages/helm/argo/argo-cd): 10.2.2, wrapping
  # Argo CD app_version v3.4.6. Pinned exactly (not with ~>) — this installs
  # CRDs, and an unplanned chart bump changing CRD shape underneath a
  # running cluster is a worse failure mode than a stale-but-known version.
  version = "10.2.2"

  namespace        = var.argocd_namespace
  create_namespace = true

  # Kept minimal on purpose: the only override this layer needs is the root
  # Application. Everything else about how Argo CD itself runs is a later
  # decision, not layer 0's to make.
  values = [
    yamlencode({
      extraObjects = [local.root_application]
    })
  ]
}
