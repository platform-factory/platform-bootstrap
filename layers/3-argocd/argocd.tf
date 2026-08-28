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

  # The one piece of Argo CD configuration layer 0 has to own: without it
  # the app-of-apps in platform-config cannot order its children.
  #
  # Argo CD removed Application from its built-in health checks in 1.8, so
  # by default a parent Application reports Healthy regardless of what its
  # child Applications are doing. platform-config's root relies on sync
  # waves between children (Crossplane core before the Crossplane provider
  # packages, whose kinds don't exist until core is running), and a wave
  # only gates on the previous wave's *health* — with no health check, the
  # gate is open and every child is created at once. This Lua script is the
  # one Argo CD's own docs give for restoring the check
  # (operator-manual/health, "Argocd App"), verified 2026-08-27; it simply
  # reports the child's own status.health back up to the parent.
  #
  # Belongs here rather than in platform-config because Argo CD reads
  # argocd-cm at startup and platform-config is what Argo CD *syncs*: a
  # setting the sync order depends on can't itself arrive by sync.
  argocd_cm = {
    configs = {
      cm = {
        "resource.customizations.health.argoproj.io_Application" = <<-LUA
          hs = {}
          hs.status = "Progressing"
          hs.message = ""
          if obj.status ~= nil then
            if obj.status.health ~= nil then
              hs.status = obj.status.health.status
              if obj.status.health.message ~= nil then
                hs.message = obj.status.health.message
              end
            end
          end
          return hs
        LUA
      }
    }
  }
}

# The root (app-of-apps) Application rides in as a SECOND helm_release of
# a tiny in-repo chart (charts/root-app), not as a kubernetes_manifest and
# not through the argo-cd chart's extraObjects value. Both of those hit
# the same chicken-and-egg — the Application CRD doesn't exist until the
# argo-cd release installs it — at two different moments:
#
#   - kubernetes_manifest validates against the live API server's schema
#     at PLAN time, so a first plan of this layer dies with "no matches
#     for kind Application" before anything has run at all.
#   - extraObjects moves the failure to APPLY time but doesn't remove it.
#     This was learned from a real failed apply (2026-08-07), not docs:
#     the design assumed Helm installs a chart's crds/ directory before
#     its templates, but the argo-cd chart TEMPLATES its CRDs (gated by
#     its crds.install value) rather than using the special crds/
#     directory — and Helm builds and validates every rendered object
#     against the cluster's API before applying any of them, so one
#     release containing both a templated CRD and an instance of it fails
#     with "ensure CRDs are installed first" on a fresh cluster.
#
# A second release sidesteps both: its objects are validated at ITS
# install time, which depends_on places after the argo-cd release has the
# CRDs live. The teardown/rebuild rhythm (C-02) re-tests this ordering on
# every session start.

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

  # Kept minimal on purpose: the ADR-0010 image overrides, plus the one
  # argocd-cm entry the app-of-apps ordering depends on (see local.argocd_cm
  # for why that can't live in platform-config). Everything else about how
  # Argo CD itself runs is a later decision, not layer 0's to make. (The
  # root Application is deliberately NOT in this release — see the comment
  # block above.)
  values = [yamlencode(local.image_overrides), yamlencode(local.argocd_cm)]
}

resource "helm_release" "root_app" {
  name      = "root-app"
  chart     = "${path.module}/charts/root-app"
  namespace = var.argocd_namespace

  values = [
    yamlencode({
      name      = "root"
      namespace = var.argocd_namespace
      project   = "default"
      source = {
        repoURL        = var.root_app_repo_url
        path           = var.root_app_path
        targetRevision = var.root_app_target_revision
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "default"
      }
      # The chart omits spec.syncPolicy entirely when this is false,
      # matching Argo CD's own default of manual-sync-if-absent.
      automatedSync = var.root_app_automated_sync
    })
  ]

  # The ordering that makes the whole two-release design work: by the time
  # this release is validated and installed, the argo-cd release above has
  # already put the Application CRD on the cluster.
  depends_on = [helm_release.argocd]
}
