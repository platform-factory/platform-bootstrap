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
   far more often than a VPC does, and it lives in the GitOps repos
   (`platform-config` and friends), where CODEOWNERS assigns ownership
   per path — security can own the policy folders while platform owns the
   Compositions — all synced continuously by Argo CD. Terraform's job is to
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
| `1-network` | VPC, subnet, baseline firewall, VPN gateway/tunnels/BGP to the peer network | ~$0 idle (VPN tunnels have a small hourly cost once enabled) | No — stays up |
| `2-cluster` | The regional GKE cluster (private nodes, Cloud NAT) and its node pool | ~$0.50/hr while it exists (regional control-plane fee + on-demand nodes) | Yes |
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
- **The root Application.** `3-argocd` installs the Argo CD "root"
  (app-of-apps) Application as a **second, tiny Helm release** (the in-repo
  chart `layers/3-argocd/charts/root-app`), after the argo-cd release it
  `depends_on`. Two more obvious designs both hit the same chicken-and-egg
  — the `Application` CRD doesn't exist until the argo-cd release installs
  it: a `kubernetes_manifest` resource fails at **plan** time (it validates
  against the live cluster's CRD schema before anything runs), and the
  argo-cd chart's `extraObjects` value fails at **apply** time — learned
  from a real failed apply, because that chart *templates* its CRDs rather
  than shipping them in Helm's special `crds/` directory, and Helm
  validates every rendered object against the cluster before applying any
  of them. A second release is validated at its own install time, when the
  CRDs are already live. Automated sync on the root Application is **off**
  for now: `platform-config` is still an empty scaffold, so there's nothing
  to sync and no reason to hand Argo CD unattended write access to the
  cluster yet.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.9
- [gcloud CLI](https://cloud.google.com/sdk/docs/install), authenticated:
  ```
  gcloud auth application-default login
  ```
- A GCP billing account you can link a new project to.
- Your current public IP, for `2-cluster`'s `authorized_networks` (the
  cluster's control-plane endpoint rejects everyone until you list at least
  one CIDR): `curl -s ifconfig.me`.

## Runbook: bootstrap from nothing

### 1. `0-foundation` — local state, then migrate to GCS

> **Already-bootstrapped infra?** The committed `backend.tf` assumes the
> state bucket exists (it does, once anyone has completed this step — the
> normal case for every clone after the first). Skip the dance below and
> just run
> `terraform init -backend-config="bucket=<project_id>-tfstate"`.
> The two-phase flow here is ONLY for a true from-nothing bootstrap.

On a genuinely empty slate, the state bucket this layer's backend points
at is itself created by this layer — so the first apply must run on local
state:

```
cd layers/0-foundation
cp terraform.tfvars.example terraform.tfvars   # skip if terraform.tfvars already exists
# edit terraform.tfvars: set billing_account (required); override project_id
# only if "platform-factory-ref" is already taken — project ids are global.
# COMMENT OUT the backend "gcs" block in backend.tf (genesis only), then:
terraform init
terraform apply
```

This creates the project, enables the APIs the later layers need, creates
the state bucket, and (per ADR-0010) creates the Artifact Registry remote
repositories the cluster's images will pull through — no extra operator
input needed for that part, it's all in `registry.tf`. All of it still
tracked in **local** state at this point. Now restore the backend block
and switch this layer onto the bucket it just created:

```
# Un-comment the backend "gcs" block in backend.tf again, then:
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
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set authorized_networks to your current public IP
# as a /32 (curl -s ifconfig.me) — required, no default. Without it the
# cluster's public control-plane endpoint accepts connections from no one,
# including you.
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

**Evolution note:** nodes are private with Cloud NAT for egress (both in
`2-cluster` — see its comments), but NAT today allows all outbound traffic
indiscriminately. FQDN-based egress restriction on top of this NAT arrives
with the fuller M3 egress-control work; this VPN section only covers the
inbound side (the site-to-site connection), which is done.

## Teardown (cost control between sessions)

The regional control-plane fee plus three on-demand `e2-standard-4` nodes
runs roughly **$0.50/hr** while `2-cluster` exists — real money if left
running, still small in absolute terms because of the rhythm below.
Destroy in the reverse order you applied, and stop at `2-cluster` —
`1-network` and `0-foundation` both stay up on purpose (the VPN connection
in particular is exactly the thing that shouldn't be rebuilt every session
— see "Why" above) and cost close to **$0** idle:

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

### `scripts/cycle.sh` — the same thing, scripted and timed

The manual sequence above is the explanation; `scripts/cycle.sh` is how it
actually gets run. It does exactly what the two `terraform destroy` calls
and the two `terraform apply` calls do, in the same order, plus three
things the manual version can't:

```
./scripts/cycle.sh down        # destroy 3-argocd, then 2-cluster
./scripts/cycle.sh up          # apply 2-cluster, then 3-argocd, then verify
./scripts/cycle.sh cycle 3     # three full down+up cycles, back to back
./scripts/cycle.sh status      # what's live right now
```

1. **It enforces the persist/disposable boundary in code.** The script
   cannot address `0-foundation` or `1-network` at all — naming either one
   is a hard error, not a warning. A teardown script that *could* destroy
   the VPC would quietly undo the reason this repo has four layers.
2. **It measures instead of accommodating.** Every terraform call runs with
   `-input=false`, so anything that would have prompted a human fails the
   run rather than waiting on one. That's deliberate: the number this is
   collecting is "manual interventions, target zero," and a script that
   politely waits for a human would report zero while hiding one.
3. **It defines "up" as the platform being back, not terraform exiting 0.**
   After both applies it fetches cluster credentials and waits for Argo CD's
   root Application to report `Synced`/`Healthy` against `platform-config`.

Each phase is appended to `scripts/cycle-results.tsv` (timestamp, cycle,
phase, layer, seconds, exit code, note) — wall-clock down and up, per layer,
across every run. That file is the evidence, so it's committed rather than
gitignored.

> **Note:** with `root_app_automated_sync = false` (the current default in
> `3-argocd`), a rebuilt root Application sits `OutOfSync` until someone
> syncs it by hand, and the verify step will fail by design rather than wait
> it out. Set `root_app_automated_sync = true` if you want the cycle to
> complete unattended — which is also the only configuration under which
> "rebuilt without manual steps" can honestly be claimed.

## What Terraform deliberately does NOT manage

Once `3-argocd` finishes, Terraform's job here is over. Everything from
that point on — application workloads, namespaces beyond `argocd`'s own,
Gateway API routes, Kyverno policies, External Secrets Operator wiring, DNS
records, anything else `platform-config`'s Argo CD Applications declare —
is GitOps's job, synced by Argo CD from that repo, not applied by
`terraform apply` here. That split is the point of layer 0: get just enough
running that GitOps can take over, then stop.

## Posture

This build is configured like a normal corporate environment, at minimal
scale — per ADR-0009 in the design-seed repo: mock a real corp environment
as much as possible over cost, since no scale is needed but the
configuration should look and behave like one. Concretely: private nodes,
Cloud NAT, a regional control plane, authorized-networks restricting the
public endpoint, on-demand (not Spot) nodes, and a VPN-ready network.

- **Image plane (ADR-0010).** All image pulls — Argo CD's own image, dex,
  redis — go through Artifact Registry remote repositories
  (`0-foundation/registry.tf`) over Private Google Access, not the public
  internet. That leaves exactly one internet egress path for the cluster:
  Argo CD's git traffic to GitHub (pulling `platform-config`) over Cloud
  NAT. M3's FQDN-based egress work formalizes that single pinhole; it
  doesn't need to add a new one.
- **Dedicated node identity.** Nodes run as a purpose-built service account
  (`0-foundation/iam.tf`), never the default Compute Engine service
  account — least-privilege (exactly `container.defaultNodeServiceAccount`
  plus `artifactregistry.reader` for the image plane above), which also
  happens to be what makes this work at all under an org that disables
  automatic IAM grants for default service accounts (true here — this
  project sits under a Google Workspace org).

Deliberate exceptions, where this build stops short of full corp-real:

- **No public Argo CD endpoint at all**, not even an authorized-networks-style
  restriction — `3-argocd` doesn't expose one yet. A real corp environment
  would put one behind SSO/an identity-aware proxy, not a bare public
  Service; that's follow-on work, not a gap this build papers over.
- **Egress isn't locked down.** Cloud NAT allows all outbound traffic
  indiscriminately today. FQDN-based egress restriction is the M3
  egress-control work, deliberately not this milestone's job.

## Where does my change go?

Two questions decide where any new thing belongs:

1. **Which lifecycle does it share?** Persists between sessions → `0-foundation`
   or `1-network`. Dies with the cluster → `2-cluster` or `3-argocd`.
2. **Is it platform floor, or a product of the platform?** Only the floor
   belongs in this repo at all. Anything a team or workload consumes arrives
   through the paved road (Crossplane claims via `platform-config`), never
   through `terraform apply` here.

| You want to add… | It goes… | Because… |
|---|---|---|
| A new VPN peer (an office, a second site) | `1-network/vpn.tf` | Shares the network's lifecycle. At the **second** peer, restructure the singular `peer_*` variables into a `for_each` map (or this repo's first local module) — don't copy-paste `_2` resources. |
| Cloud NAT | `2-cluster/nat.tf` | It serves nodes, so it's created and destroyed on their schedule. Exists because nodes are private (ADR-0009's corp-real posture); as of ADR-0010 its only real consumer is Argo CD's git egress to GitHub, since images no longer need it. |
| Images from a new external registry | An Artifact Registry remote repo in `0-foundation/registry.tf` | Mirrors the image-plane split (ADR-0010): the cache persists like the network does, not the cluster. Verify the upstream is actually AR-remote-proxyable against the Artifact Registry product docs before adding it — the Terraform schema won't stop you from configuring one that doesn't work. |
| Another platform-substrate network (hub/egress VPC) | `1-network/network.tf` | Floor-level reachability, persists. Same second-instance rule as VPN peers. |
| A database, bucket, namespace, or VPC **for a workload/tenant** | **Not this repo.** An XR claim in the team's repo or `systems/`, materialized by Compositions | Terraform ends at layer 0 (claim C-01). Putting it here routes around every approval boundary the platform exists to enforce. |
| A cluster addon (Kyverno, ESO, external-dns, Gateway…) | `platform-config`, synced by Argo CD | The running platform is GitOps-owned. `3-argocd` installs Argo CD itself and nothing else. |
| Argo CD's own configuration | `platform-config` once it has content; `3-argocd` values only if Argo can't boot without it | Keep layer 0 minimal — it should never need touching to change how the platform behaves. |

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
(`1-network` validated with `enable_vpn` both true and false; `2-cluster`
validated with a representative `authorized_networks` value). Corp-real
posture (private nodes, Cloud NAT, regional control plane, authorized
networks, on-demand nodes) applied per ADR-0009. Image plane moved to
Artifact Registry remote repositories per ADR-0010. Not yet applied against
real infrastructure.
