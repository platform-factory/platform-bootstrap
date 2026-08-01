# platform-bootstrap

This repo is the Terraform layer 0 for the Platform Factory: it stands up the cloud project, VPC, GKE cluster, workload identity, and bootstraps Argo CD. Once Argo CD is running, this is Terraform's last job — everything after this point is managed via GitOps.

## Part of the Platform Factory

This repo is one of seven that make up the reference implementation of the
**Platform Factory** pattern. The design seed — pattern docs, ADRs, and the
build plan — lives at [https://github.com/thecloudgeek/platform-factory](https://github.com/thecloudgeek/platform-factory).

This repo is built out in **M1**.

## Status

**Status:** scaffold — build in progress, following the pre-registered build plan in the design seed repo.
