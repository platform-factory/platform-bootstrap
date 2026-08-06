# platform-bootstrap

Terraform layer 0 for the Platform Factory reference implementation: the
cloud project, VPC, GKE cluster, workload identity, and Argo CD itself. Once
Argo CD is running and pointed at [platform-config](https://github.com/platform-factory/platform-config),
this repo's job is done — everything from there on is managed via GitOps,
not Terraform.

## Why (the mental model)

Two things are true about a reference build like this one:

1. **Most of the platform shouldn't be Terraform's problem.** Namespaces,
   workloads, Gateway routes, policies, secrets wiring — all of that changes
   far more often than a VPC does, and it belongs to whoever owns
   `platform-config`, synced continuously by Argo CD. Terraform's job is to
   get *just enough* running that Argo CD can take over: a project, a
   cluster, and Argo CD itself. That's it. Hence "layer 0" — everything
   above it is a different system's job.

2. **Not all of that "just enough" is equally expensive to keep around.** A
   GCP project and an empty GCS bucket cost nothing sitting idle. A running
   GKE cluster with worker nodes costs money every hour it exists. If this
   repo is going to be rebuilt and torn down across working sessions (it
   is — see `docs/build-log/` in the design-seed repo), those two facts need
   to live in *different* blast radii, so destroying the expensive one never
   touches the cheap one.

That's the whole reason for three layers instead of one Terraform root:

| Layer | Owns | Cost to leave running | Torn down between sessions? |
|---|---|---|---|
| `0-foundation` | GCP project, enabled APIs, the Terraform state bucket | ~$0 | No — stays up |
| `1-cluster` | VPC, subnet, the GKE cluster and its node pool | Real (nodes running) | Yes |
| `2-argocd` | Argo CD itself, running on the cluster | Free (rides on 1-cluster) | Yes, alongside 1-cluster |

Each layer is applied and destroyed independently, with its own Terraform
state. `1-cluster` and `2-argocd` read facts they need from the layer below
via `terraform_remote_state` (project id, region, cluster endpoint, ...)
instead of having those values typed in twice — see each layer's
`providers.tf`.

## Mechanism

- **State.** All three layers' state lives in one GCS bucket
  (`<project_id>-tfstate`, created by `0-foundation`), separated by prefix
  (`0-foundation`, `1-cluster`, `2-argocd`). `0-foundation` is the one
  exception: it starts on **local** state, because it's the layer that
  *creates* that bucket — it can't depend on a bucket that doesn't exist
  yet. The runbook below covers the one-time switch to GCS once it does.
- **Chaining.** `1-cluster` reads `0-foundation`'s outputs.
  `2-argocd` reads `1-cluster`'s outputs (which themselves pass
  `0-foundation`'s project id and region through) — each layer depends only
  on its immediate predecessor, not the whole chain directly.
- **The root Application.** `2-argocd` renders the Argo CD "root"
  (app-of-apps) Application through the `argo-cd` chart's `extraObjects`
  value, not a separate `kubernetes_manifest` resource. A `kubernetes_manifest`
  for an `Application` object gets validated against the live cluster's CRD
  schema at **plan** time — and on a true first apply of this layer, that
  CRD doesn't exist until this very `helm_release` installs it. `extraObjects`
  avoids the chicken-and-egg because Helm installs a chart's CRDs before its
  templates in the same release, so the CRD and the root Application land
  together. Automated sync on that root Application is **off** for now:
  `platform-config` is still an empty scaffold, so there's nothing to sync
  and no reason to hand Argo CD unattended write access to the cluster yet.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.9
- [gcloud CLI](https://cloud.google.com/sdk/docs/install), authenticated:
  ```
  gcloud auth application-default login
  ```
- A GCP billing account you can link a new project to.

## Runbook: bootstrap from nothing

### 1. `0-foundation` — local state, then migrate to GCS

```
cd layers/0-foundation
cp terraform.tfvars.example terraform.tfvars   # skip if terraform.tfvars already exists
# edit terraform.tfvars: set billing_account (required); override project_id
# only if "platform-factory-ref" is already taken — project ids are global.
terraform init
terraform apply
```

This creates the project, enables the APIs the later layers need, and
creates the state bucket — all still tracked in **local** state at this
point. Now switch this layer onto that bucket:

```
# Uncomment the backend "gcs" block in backend.tf, then:
terraform init -backend-config="bucket=$(terraform output -raw tfstate_bucket)" -migrate-state
```

Answer "yes" when prompted to copy state to the new backend. From here on,
`0-foundation`'s state lives in GCS like every other layer's.

### 2. `1-cluster` — VPC + GKE

```
cd ../1-cluster
terraform init -backend-config="bucket=<same bucket name as above>"
terraform apply
```

(If `project_id` in `0-foundation`'s `terraform.tfvars` was overridden from
the default, set the same value in this layer's `terraform.tfvars` too — see
its `terraform.tfvars.example`. This is the one deliberate exception to
"only foundation takes raw inputs": Terraform's GCS backend can't be
parameterized by another layer's output, so each layer needs to be told
directly which bucket to read before it can read anything else from it.)

### 3. `2-argocd` — Argo CD, pointed at platform-config

```
cd ../2-argocd
terraform init -backend-config="bucket=<same bucket name>"
terraform apply
```

Once this finishes, Argo CD is running in the `argocd` namespace with a
"root" Application already pointed at `platform-config`, sync not yet
automated. `kubectl get applications -n argocd` (with your kubeconfig
pointed at the new cluster) should show it.

## Teardown (cost control between sessions)

Destroy in the reverse order you applied, and stop at `1-cluster` —
`0-foundation` stays up on purpose (it costs nothing idle):

```
cd layers/2-argocd
terraform destroy

cd ../1-cluster
terraform destroy
```

To come back later: re-run `terraform init -backend-config=...` (your local
`.terraform/` directory is gitignored and disposable) and `terraform apply`
in `1-cluster`, then the same in `2-argocd`. `0-foundation` never needs to
be touched again unless you're tearing the whole reference build down for
good.

## What Terraform deliberately does NOT manage

Once `2-argocd` finishes, Terraform's job here is over. Everything from that
point on — application workloads, namespaces beyond `argocd`'s own, Gateway
API routes, Kyverno policies, External Secrets Operator wiring, DNS records,
anything else `platform-config`'s Argo CD Applications declare — is GitOps's
job, synced by Argo CD from that repo, not applied by `terraform apply` here.
That split is the point of layer 0: get just enough running that GitOps can
take over, then stop.

## Modules

There are no local Terraform modules in this repo. Nothing repeats enough
across the three layers to be worth naming as a shared unit — a module
wrapping a single VPC or a single cluster would be indirection with no
abstraction value. If that changes (e.g. a real multi-environment build
reusing the same cluster shape), it's a reason to add one then, not now.

## Part of the Platform Factory

This repo is one of seven that make up the reference implementation of the
**Platform Factory** pattern. The design seed — pattern docs, ADRs, and the
build plan — lives at [https://github.com/thecloudgeek/platform-factory](https://github.com/thecloudgeek/platform-factory).

This repo is built out in **M1**.

## Status

**Status:** M1 in progress — layer 0 (this repo) authored: `0-foundation`,
`1-cluster`, `2-argocd` all written and `terraform validate`-clean. Not yet
applied against real infrastructure.
