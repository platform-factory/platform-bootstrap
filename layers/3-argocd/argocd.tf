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

  # The Argo CD configuration the bootstrap layers have to own, because
  # Argo CD reads argocd-cm at startup and platform-config is what Argo CD
  # *syncs* — a setting the sync order depends on cannot itself arrive by
  # sync. One entry at M1 (the Application health check below, without which
  # the app-of-apps in platform-config cannot order its children); two more
  # at M2 (the XR health checks, without which an Application containing
  # System or Database XRs reports Healthy the INSTANT the objects are
  # created — Argo CD has no health script for platform.thecloudgeek.io, and
  # a resource with no health check contributes no health at all, verified
  # 2026-09-16 against argo-cd v3.4.6 util/lua/lua.go GetHealthScript). Note
  # the M2 failure is a premature green, not a hang: a reader who expects a
  # stuck sync will go looking in the wrong place.
  #
  # The rule of thumb for this map is that it holds Argo CD's own view of
  # resource health — the part of Argo's configuration that cannot
  # meaningfully arrive through the thing Argo syncs. Everything else
  # belongs in platform-config.
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
  # Health for the platform's own composite resources (M2). Same placement
  # reasoning as the Application check above: an Application containing
  # System or Database XRs reports Healthy the moment the objects exist
  # unless a script says otherwise, so without this the `systems` wave
  # "completes" while nothing has actually reconciled.
  #
  # WHAT THAT ACTUALLY BREAKS, precisely, because the obvious answer is
  # wrong. It is NOT sync ordering: `systems` is the highest wave in M2
  # (crossplane 0, crossplane-providers 1, crossplane-platform/kyverno 2,
  # compositions/kyverno-policies 3, systems 4), so nothing downstream is
  # gated on it and no later wave can start against a half-built tenant
  # namespace. What it breaks is the finish line in scripts/cycle.sh, which
  # blocks until every Application reports Synced AND Healthy and dies on
  # timeout. Without these entries that gate passes the moment the XR
  # objects exist, and a cycle gets recorded green with nothing reconciled —
  # the same false-green class the durable-resource adoption check at the
  # top of cycle.sh was added to close. The second value is diagnostic:
  # Crossplane names the stuck composed resource in its Ready message and
  # the script below passes it through, so the Argo UI says which one.
  # (Restore the wave-ordering argument only if a wave is ever placed after
  # `systems`.)
  #
  # C-01, stated rather than glossed: this is a Terraform change, and
  # C-01 counts terraform applies after M1. It rides in the same 3-argocd
  # apply as the rest of this layer's M2 work so the count stays one
  # crossing per layer — not free because the layer is disposable.
  #
  # WHY ONLY platform.thecloudgeek.io. Argo CD 3.4.6 already ships wildcard
  # built-ins that cover everything else in play — resource_customizations/
  # _.crossplane.io/_/health.lua and _.upbound.io/_/health.lua, where the
  # directory `_` is Argo's stand-in for `*` (verified 2026-09-16 by reading
  # the v3.4.6 tree and util/lua/lua.go, which does a literal `_`→`*` replace
  # and then a doublestar match on "<group>/<Kind>"). Those cover the
  # Crossplane XRD/Composition/Provider objects AND every provider-upjet-gcp
  # managed resource, because sql.gcp.m.upbound.io ends in .upbound.io. An
  # entry of ours for those groups would not add anything — it would SHADOW
  # the built-in, since argocd-cm is checked before the built-ins. So the
  # only gap is our own XRD group, which ends in .thecloudgeek.io and
  # matches no built-in.
  #
  # WHY TWO ENUMERATED KEYS AND NOT ONE WILDCARD. Argo's own docs
  # (operator-manual/health.md, v3.4.6): "wildcards are only supported when
  # using the resource.customizations key, the
  # resource.customizations.health.<group>_<kind> style keys do not work
  # since wildcards (*) are not supported in Kubernetes configmap keys."
  # `*` is not a legal ConfigMap key character, so a key of
  # `...platform.thecloudgeek.io_*` would be silently ignored — no error,
  # just XRs stuck Progressing forever. Two kinds is two lines; a third XRD
  # is a one-line PR.
  #
  # THE SCRIPT. Crossplane XRs publish exactly two conditions, Synced and
  # Ready (docs.crossplane.io/v2.3, composite-resources). Synced is checked
  # FIRST and wins, because Crossplane can set Synced=False and Ready=False
  # at the same time and a single loop would then be order-dependent: a
  # Composition that cannot render is a Degraded thing an operator must go
  # look at, not a Progressing thing that will resolve itself. When Ready is
  # False, Crossplane's message names the unready composed resources
  # ("Unready resources: quota, rolebinding, ..."), so passing it through
  # verbatim is what makes the Argo UI say WHICH resource is stuck instead
  # of just that something is.
  #
  # Lua sandbox constraint, verified 2026-09-16 against argo-cd v3.4.6
  # util/lua/lua.go: scripts from argocd-cm run with useOpenLibs = false,
  # which still opens base, table, package and a safe os — but NOT the
  # string library. So `..` concatenation is available and string.format is
  # not. Do not "tidy" this into string.format; it would fail at runtime.
  xr_health_lua = <<-LUA
    local hs = {}
    hs.status = "Progressing"
    hs.message = "Waiting for the composition to reconcile"

    if obj.status == nil or obj.status.conditions == nil then
      return hs
    end

    for _, c in ipairs(obj.status.conditions) do
      if c.type == "Synced" and c.status == "False" then
        hs.status = "Degraded"
        hs.message = (c.reason or "SyncFailed") .. ": " .. (c.message or "")
        return hs
      end
    end

    for _, c in ipairs(obj.status.conditions) do
      if c.type == "Ready" then
        if c.status == "True" then
          hs.status = "Healthy"
          hs.message = "Resource is up to date"
        else
          hs.status = "Progressing"
          hs.message = (c.reason or "Creating") .. ": " .. (c.message or "")
        end
        return hs
      end
    end

    return hs
  LUA

  argocd_cm = {
    configs = {
      cm = {
        # One entry per XRD kind — see local.xr_health_lua for why this
        # cannot be a wildcard and why no *.upbound.io entry belongs here.
        "resource.customizations.health.platform.thecloudgeek.io_System"   = local.xr_health_lua
        "resource.customizations.health.platform.thecloudgeek.io_Database" = local.xr_health_lua

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
