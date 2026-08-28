# ADR-0010: the cluster's image plane moves to Artifact Registry remote
# repositories, so image pulls ride the Google-API path (Private Google
# Access, from 1-network's subnet) instead of general internet egress. Once
# this is live, Cloud NAT's (2-cluster/nat.tf) only remaining consumer is
# Argo CD's git traffic to GitHub — a pinhole M3's FQDN egress work will
# formalize, not eliminate.
#
# Each resource below is a REMOTE_REPOSITORY: a read-only, pull-through
# cache in front of one upstream registry. Lives here, not 1-network or
# 2-cluster, because these mirror image content that outlives any one
# cluster rebuild — same "persist the floor, rebuild the compute" logic as
# the network split.
#
# Upstream support verified 2026-08-06 against the Artifact Registry
# product docs (docs.cloud.google.com/artifact-registry/docs/repositories/remote-overview)
# and, for quay.io specifically (not in that doc's example table), a live
# `gcloud artifacts repositories describe` output pasted into
# github.com/hashicorp/terraform-provider-google/issues/20278 showing a
# real quay.io remote repo in production. Do not add more upstreams here
# without the same check — the Terraform schema will happily accept a URI
# that Artifact Registry's backend won't actually proxy.

# Docker Hub: the one Google preset (public_repository = "DOCKER_HUB").
# Not currently pulled by anything this repo installs — Argo CD's chart
# doesn't touch Docker Hub (see the quay/ghcr/ecr-public repos below for
# what it actually needs) — kept as a general-purpose upstream for
# whatever needs a plain library/* image later.
resource "google_artifact_registry_repository" "docker_hub" {
  project       = google_project.this.project_id
  location      = var.region
  repository_id = "docker-hub"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  description   = "Remote cache of Docker Hub (general-purpose; not yet consumed by anything this repo installs)."

  remote_repository_config {
    description = "Docker Hub"
    docker_repository {
      public_repository = "DOCKER_HUB"
    }
  }

  depends_on = [google_project_service.this]
}

# quay.io: Argo CD's own image (global.image.repository in the chart) comes
# from here. Custom URI, not a preset — confirmed working per the
# terraform-provider-google issue #20278 note above.
resource "google_artifact_registry_repository" "quay_io" {
  project       = google_project.this.project_id
  location      = var.region
  repository_id = "quay-io"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  description   = "Remote cache of quay.io — Argo CD's own image (quay.io/argoproj/argocd) comes from here."

  remote_repository_config {
    description = "quay.io"
    common_repository {
      uri = "https://quay.io"
    }
  }

  depends_on = [google_project_service.this]
}

# ghcr.io: Argo CD's dex image comes from here, and so does everything
# Crossplane — its core image (xpkg.crossplane.io/crossplane/crossplane)
# and every provider package (xpkg.crossplane.io/crossplane-contrib/*),
# because xpkg.crossplane.io is a pass-through front for ghcr.io (verified
# by registry probe 2026-08-11; every M1 image pulled through this remote
# 2026-08-27). platform-config maps that prefix here with one Crossplane
# ImageConfig. Kyverno's images are expected to land here too (M2).
# Explicitly listed as a supported custom Docker upstream in Google's own
# remote-overview docs.
resource "google_artifact_registry_repository" "ghcr_io" {
  project       = google_project.this.project_id
  location      = var.region
  repository_id = "ghcr-io"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  description   = "Remote cache of ghcr.io — Argo CD's dex image (ghcr.io/dexidp/dex) comes from here."

  remote_repository_config {
    description = "GitHub Container Registry"
    common_repository {
      uri = "https://ghcr.io"
    }
  }

  depends_on = [google_project_service.this]
}

# AWS ECR Public Gallery: Argo CD's redis image comes from here — the
# chart's own default is "ecr-public.aws.com/docker/library/redis", an
# alias for the same backend Google's docs list as "public.ecr.aws" (both
# hostnames resolve and answer with the identical
# www-authenticate: service="public.ecr.aws" challenge, confirmed by hand).
# This is a genuine finding, not the original assumption: the task's
# starting list expected Docker Hub to cover redis; the pinned chart
# (10.2.2) actually pulls it from here instead.
resource "google_artifact_registry_repository" "ecr_public" {
  project       = google_project.this.project_id
  location      = var.region
  repository_id = "ecr-public"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  description   = "Remote cache of the AWS ECR Public Gallery — Argo CD's redis image comes from here."

  remote_repository_config {
    description = "AWS ECR Public Gallery"
    common_repository {
      uri = "https://public.ecr.aws"
    }
  }

  depends_on = [google_project_service.this]
}

# registry.k8s.io: not consumed by anything this repo installs yet —
# external-dns and other upstream Kubernetes-project images land here
# starting M2/M3. Explicitly listed as a supported custom Docker upstream
# in Google's own remote-overview docs.
resource "google_artifact_registry_repository" "registry_k8s_io" {
  project       = google_project.this.project_id
  location      = var.region
  repository_id = "registry-k8s-io"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  description   = "Remote cache of registry.k8s.io (not yet consumed by anything this repo installs; arrives M2/M3)."

  remote_repository_config {
    description = "Kubernetes Container Registry"
    common_repository {
      uri = "https://registry.k8s.io"
    }
  }

  depends_on = [google_project_service.this]
}

# xpkg.upbound.io: Crossplane packages (M2), not yet consumed by anything
# this repo installs. Weaker verification than the repos above — it isn't
# in Google's documented examples or in a known working issue thread the
# way quay.io is. Confirmed only that it speaks the standard Docker
# Registry V2 API (a direct HTTP probe returns the expected
# docker-distribution-api-version: registry/2.0 header and bearer
# challenge), which is what Artifact Registry's Docker remote-repo proxy
# requires — re-verify against a real apply before relying on this one at
# M2.
resource "google_artifact_registry_repository" "xpkg_upbound_io" {
  project       = google_project.this.project_id
  location      = var.region
  repository_id = "xpkg-upbound-io"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  description   = "Remote cache of xpkg.upbound.io (not yet consumed; arrives M2 with Crossplane). Verified Docker V2 API-compliant, not verified as an actual working AR remote — recheck at M2."

  remote_repository_config {
    description = "Upbound package registry (xpkg)"
    common_repository {
      uri = "https://xpkg.upbound.io"
    }
  }

  depends_on = [google_project_service.this]
}
