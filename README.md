# platform-bootstrap

Terraform layer 0 for the Platform Factory reference implementation: the
cloud project, network, GKE cluster, workload identity, and Argo CD itself.
Once Argo CD is running and pointed at [platform-config](https://github.com/platform-factory/platform-config),
this repo's job is done — everything from there on is managed via GitOps,
not Terraform.

## Why (the mental model)

Three things are true about a reference build like this one:

1. **Most of the platform shouldn't be Terraform's problem.** Namespaces,
   workloads, Gateway routes, policies, secrets wiring — all of that changes
   far more often than a VPC does, and it belongs to whoever owns
   `platform-config`, synced continuously by Argo CD. Terraform's job is to
   get *just enough* running that Argo CD can take over: a project, a
   network, a cluster, and Argo CD itself. That's it. Hence "layer 0" —
   everything above it is a different system's job.

2. **Not everything in that "just enough" is equally expensive to keep
   around.** A GCP project and an empty GCS bucket cost nothing sitting
   idle. A running GKE cluster with worker nodes costs money every hour it
   exists. If this repo is going to be rebuilt and torn down across working
   sessions (it is — see `docs/build-log/` in the design-seed repo), those
   two facts need to live in *different* blast radii, so destroying the
   expensive one never touches the cheap one.

3. **The network is a persistent fact, not a disposable one.** In a real
   corporate environment the cloud doesn't live by itself — the network and
   its connections to other networks persist; compute is disposable. This
   build has exactly that shape in miniature: a VPN connects this VPC to a
   home network for testing, and HA VPN gateways get new Google-side public
   IPs every time they're recreated. A VPC that died and was rebuilt between
   sessions would force manual peer reconfiguration on the other end every
   single time. So the VPC — and its VPN connection — has to outlive the
   cluster, not just the whole reference build outlive nothing.

That's the reasoning behind four layers instead of one Terraform root:

| Layer | Owns | Cost to leave running | Torn down between sessions? |
|---|---|---|---|
| `0-foundation` | GCP project, enabled APIs, the Terraform state bucket | ~$0 | No — stays up |
| `1-network` | VPC, subnet, VPN gateway/tunnels/BGP to the peer network | ~$0 idle (VPN tunnels have a small hourly cost once enabled) | No — stays up |
| `2-cluster` | The zonal GKE cluster and its node pool | Real (nodes running) | Yes |
| `3-argocd` | Argo CD itself, running on the cluster | Free (rides on 2-cluster) | Yes, alongside 2-cluster |

Each layer is applied and destroyed independently, with its own Terraform
state. Each layer reads facts it needs from the layer directly below it via
`terraform_remote_state` (project id, region, network name, cluster
endpoint, ...) instead of having those values typed in twice, and instead
of reaching back more than one hop — see each layer's `providers.tf`.

## Mechanism

- **State.** All four layers' state lives in one GCS bucket
  (`<project_id>-tfstate`, created by `0-foundation`), separated by prefix
  (`0-foundation`, `1-network`, `2-cluster`, `3-argocd`). `0-foundation` is
  the one exception: it starts on **local** state, because it's the layer
  that *creates* that bucket — it can't depend on a bucket that doesn't
  exist yet. The runbook below covers the one-time switch to GCS once it
  does.
- **Chaining.** `1-network` reads `0-foundation`'s outputs. `2-cluster`
  reads `1-network`'s outputs (which pass `0-foundation`'s project id and
  region through, plus the network's own facts). `3-argocd` reads
  `2-cluster`'s outputs (which pass project id and region through again).
  Each layer depends only on its immediate predecessor, never two hops back.
- **The root Application.** `3-argocd` renders the Argo CD "root"
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

### 2. `1-network` — VPC + subnet (+ VPN, once the peer is ready)

```
cd ../1-network
terraform init -backend-config="bucket=<same bucket name as above>"
terraform apply
```

(If `project_id` in `0-foundation`'s `terraform.tfvars` was overridden from
the default, set the same value in this layer's `terraform.tfvars` too — see
its `terraform.tfvars.example`. This is the one deliberate exception to
"only foundation takes raw inputs": Terraform's GCS backend can't be
parameterized by another layer's output, so each layer needs to be told
directly which bucket to read before it can read anything else from it.
Every layer below needs this same override.)

By default `enable_vpn = false`, so this apply just creates the VPC and
subnet. See **VPN** below for turning the tunnel on.

### 3. `2-cluster` — the GKE cluster

```
cd ../2-cluster
terraform init -backend-config="bucket=<same bucket name>"
terraform apply
```

### 4. `3-argocd` — Argo CD, pointed at platform-config

```
cd ../3-argocd
terraform init -backend-config="bucket=<same bucket name>"
terraform apply
```

Once this finishes, Argo CD is running in the `argocd` namespace with a
"root" Application already pointed at `platform-config`, sync not yet
automated. `kubectl get applications -n argocd` (with your kubeconfig
pointed at the new cluster) should show it.

## VPN

The peer side (a UniFi gateway, for this build) needs to support **BGP**,
not just static routes: GCP HA VPN's recommended and most robust mode uses
BGP over both tunnels so routes propagate automatically and failover
between tunnels works without manual route updates. Current UniFi hardware
running UniFi OS 4.3+ / Network Application 9.x (the Cloud Gateway family —
UDM, UCG) supports BGP natively via **Settings → Policy Engine → Policy
Table → Dynamic Routing** — see Ubiquiti's own docs: [UniFi - Border
Gateway Protocol (BGP)](https://help.ui.com/hc/en-us/articles/16271338193559-UniFi-Border-Gateway-Protocol-BGP).
Older or non-Cloud-Gateway UniFi hardware may not have this natively and
would need a manual FRR-based workaround — confirm your specific gateway
model and firmware support BGP before turning this on. (Classic VPN with
static routes is a fallback that doesn't require BGP on the peer, but it's
not built here — cross that bridge only if the peer side turns out unable
to do BGP.)

Once the peer gateway's public IP and BGP ASN are known:

```
cd layers/1-network
# in terraform.tfvars:
#   enable_vpn        = true
#   peer_gateway_ip   = "<peer WAN IP>"
#   vpn_shared_secret = "<a real generated PSK, matching what you configure on the peer>"
terraform apply
```

This brings up an HA VPN gateway (two Google-managed interfaces), an
external gateway object representing the peer, two tunnels (one per
interface — a real HA pair, not a single link), a Cloud Router, and BGP
sessions on both tunnels. By default it advertises the subnet's primary
range plus both secondary (pod/Service) ranges to the peer, so traffic from
the home/corp side can reach pods and Services, not just node IPs. Run
`terraform output vpn_gateway_ips` after applying to get the two
Google-side public IPs to configure as peer addresses on the UniFi gateway.

**Evolution note:** nodes are on public IPs today — no Cloud NAT, no
private-nodes configuration. That arrives with the egress-control work
(M3), and Cloud NAT will live in `2-cluster`, not here: it serves nodes, so
it should be created and destroyed on the same schedule they are, not
persist with the network.

## Teardown (cost control between sessions)

Destroy in the reverse order you applied, and stop at `2-cluster` —
`1-network` and `0-foundation` both stay up on purpose (the VPN connection
in particular is exactly the thing that shouldn't be rebuilt every session
— see "Why" above):

```
cd layers/3-argocd
terraform destroy

cd ../2-cluster
terraform destroy
```

To come back later: re-run `terraform init -backend-config=...` (your local
`.terraform/` directory is gitignored and disposable) and `terraform apply`
in `2-cluster`, then the same in `3-argocd`. `0-foundation` and `1-network`
never need to be touched again unless you're tearing the whole reference
build down for good.

## What Terraform deliberately does NOT manage

Once `3-argocd` finishes, Terraform's job here is over. Everything from
that point on — application workloads, namespaces beyond `argocd`'s own,
Gateway API routes, Kyverno policies, External Secrets Operator wiring, DNS
records, anything else `platform-config`'s Argo CD Applications declare —
is GitOps's job, synced by Argo CD from that repo, not applied by
`terraform apply` here. That split is the point of layer 0: get just enough
running that GitOps can take over, then stop.

## Modules

There are no local Terraform modules in this repo. Nothing repeats enough
across the four layers to be worth naming as a shared unit — a module
wrapping a single VPC or a single cluster would be indirection with no
abstraction value. If that changes (e.g. a real multi-environment build
reusing the same network or cluster shape), it's a reason to add one then,
not now.

## Part of the Platform Factory

This repo is one of seven that make up the reference implementation of the
**Platform Factory** pattern. The design seed — pattern docs, ADRs, and the
build plan — lives at [https://github.com/thecloudgeek/platform-factory](https://github.com/thecloudgeek/platform-factory).

This repo is built out in **M1**.

## Status

**Status:** M1 in progress — layer 0 (this repo) authored: `0-foundation`,
`1-network`, `2-cluster`, `3-argocd` all written and `terraform validate`-clean
(`1-network` validated both with `enable_vpn` true and false). Not yet
applied against real infrastructure.
