# ADR-0010: image pulls ride Artifact Registry remote repos over Private
# Google Access instead of the public internet — nodes are private
# (2-cluster) and this keeps image pulls off Cloud NAT entirely (see
# nat.tf's comment in 2-cluster). The chart itself, by contrast, is fetched
# by Terraform from the operator's laptop when `helm_release` runs, not by
# the cluster — so chart-repo (argoproj.github.io) egress is not a cluster
# concern and isn't rerouted here.
#
# Repository paths below preserve the chart's own upstream path structure
# exactly (see each comment) — only the host+first-segment changes, so
# these pull the identical images the chart would otherwise pull directly.
# Version pins (global.image.tag, dex.image.tag, ...) are untouched; only
# .repository keys are overridden.
locals {
  ar_base     = data.terraform_remote_state.cluster.outputs.artifact_registry_base
  ar_repo_ids = data.terraform_remote_state.cluster.outputs.artifact_registry_repo_ids

  image_overrides = {
    # was quay.io/argoproj/argocd — global.image.repository applies to
    # every Argo CD component (server, repo-server, controllers, ...)
    # that doesn't set its own image.repository.
    global = {
      image = {
        repository = "${local.ar_base}/${local.ar_repo_ids.quay_io}/argoproj/argocd"
      }
    }

    # was ghcr.io/dexidp/dex
    dex = {
      image = {
        repository = "${local.ar_base}/${local.ar_repo_ids.ghcr_io}/dexidp/dex"
      }
    }

    # was ecr-public.aws.com/docker/library/redis (an alias for the same
    # AWS ECR Public Gallery service Google's own docs list as
    # public.ecr.aws — see 0-foundation/registry.tf's comment)
    redis = {
      image = {
        repository = "${local.ar_base}/${local.ar_repo_ids.ecr_public}/docker/library/redis"
      }
    }
  }
}

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

  # Kept minimal on purpose: the root Application and the ADR-0010 image
  # overrides above are the only overrides this layer needs. Everything
  # else about how Argo CD itself runs is a later decision, not layer 0's
  # to make.
  values = [
    yamlencode(merge(
      local.image_overrides,
      { extraObjects = [local.root_application] }
    ))
  ]
}
