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
| `1-network` | VPC, subnet, baseline firewall, Cloud NAT, the Tailscale subnet-router jump box, and a gated VPN gateway/tunnels/BGP to a peer network | A few dollars a month (the always-on e2-micro jump box; an idle NAT gateway is ~$0, and the VPN adds a small hourly cost only if enabled) | No — stays up |
| `2-cluster` | The regional GKE cluster (private nodes, DNS-based control-plane endpoint) and its node pool | ~$0.50/hr while it exists (regional control-plane fee + on-demand nodes) | Yes |
| `3-argocd` | Argo CD itself, running on the cluster | Free (rides on 2-cluster) | Yes, alongside 2-cluster |

Each layer is applied and destroyed independently, with its own Terraform
state. Each layer reads facts it needs from the layer directly below it via
`terraform_remote_state` (project id, region, network name, cluster
endpoint, ...) instead of having those values typed in twice, and instead
of reaching back more than one hop — see each layer's `providers.tf`.

## Mechanism

An editable diagram of everything below, as deployed, lives in
[`docs/architecture/`](docs/architecture/) (`.drawio` source plus a rendered
PNG).


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
  CRDs are already live. Automated sync on the root Application is **on**
  (prune and self-heal, since 2026-08-13): the moment the root Application
  exists, Argo CD pulls `platform-config`'s `apps/` directory and takes
  over with no human sync click — which is what lets `scripts/cycle.sh`
  claim a rebuild happened without manual steps.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.9
- [gcloud CLI](https://cloud.google.com/sdk/docs/install), authenticated:
  ```
  gcloud auth application-default login
  ```
- A GCP billing account you can link a new project to.
- Nothing about where you are sitting. The cluster's control plane is
  reached by its DNS-based endpoint and authorized by IAM, so there is no
  address to look up and no allowlist to keep current (ADR-0011).

## Access: how you reach things

Two planes, deliberately separate, with no shared failure mode.

**Control plane (`kubectl`, Terraform).** The cluster's DNS-based endpoint,
authorized by IAM. Nothing to configure and nothing to keep current:

```
gcloud container clusters get-credentials <cluster> --region <region> --dns-endpoint
```

**Data plane (apps, SSH, databases on private IPs).** The jump box in
`1-network` runs a Tailscale subnet router advertising the VPC's private
ranges, so a private address is reachable directly — `psql -h 10.x.x.x` — from
any device on the tailnet.

**Break-glass.** IAP TCP forwarding to the jump box. It needs no egress, so it
works when NAT is down, the tailnet is broken, or a Tailscale key has expired:

```
gcloud compute ssh $(terraform -chdir=layers/1-network output -raw jumpbox_name) \
  --tunnel-through-iap \
  --zone $(terraform -chdir=layers/1-network output -raw jumpbox_zone)
```

This needs `roles/iap.tunnelResourceAccessor` on the project. The jump box has
no external IP; ingress is allowed only from `35.235.240.0/20`, which is
Google's IAP fleet, and only after IAP has checked the caller's IAM identity.

### One-time: join the jump box to the tailnet

The startup script installs Tailscale and enables kernel forwarding, but does
not run `tailscale up` — joining needs an auth key, and putting one in instance
metadata would write a credential into Terraform state and into the metadata
server. So the join is a manual step, once per jump box, over IAP:

```
terraform -chdir=layers/1-network output -raw jumpbox_tailscale_up_command
```

SSH in with the break-glass command above and run what that prints. Then
**approve the advertised routes in the Tailscale admin console** — they are
advertised but unusable until approved. Enable Tailnet Lock while you are
there (ADR-0011 names it as the mitigation for the one real risk of a SaaS
coordination server).

The node stays joined across reboots. Only a rebuilt jump box needs this again.

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
# No edit required for access. The control plane exposes only its DNS-based
# endpoint (IP endpoints are disabled) and IAM decides who gets in, so there
# is no operator IP to supply. Edit node_locations only if the apply fails
# with GCE_STOCKOUT.
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
"root" Application pointed at `platform-config`'s `apps/` directory, auto-sync
on (prune and self-heal). Within a few minutes `kubectl get applications -n
argocd` (with your kubeconfig pointed at the new cluster) should show the
root plus one child Application per file in that directory, all
`Synced`/`Healthy`; `scripts/cycle.sh up` waits for exactly that.

### 5. M2 — bringing up the paved road on an already-bootstrapped project

M2 adds tenants, a real Cloud SQL database and Google-Group RBAC. None of that
is reachable by a single `terraform apply`, and the order below is not a
preference — each step is a hard prerequisite of the one after it. This is the
consolidated list; the reasoning behind each line lives in the file it touches.

**A. Google Workspace (a Workspace admin, not Terraform).** Nothing on the
Google side of the platform resolves until these exist. Create the umbrella
group — the local part must be exactly `gke-security-groups`, GKE requires that
name — then the team groups, then nest the teams *inside* the umbrella as
member groups rather than adding individuals:

```
gcloud identity groups create gke-security-groups@thecloudgeek.io \
  --organization=thecloudgeek.io --group-display-name="GKE security groups" \
  --labels=cloudidentity.googleapis.com/groups.discussion_forum
gcloud identity groups create payments@thecloudgeek.io \
  --organization=thecloudgeek.io --group-display-name="Payments" \
  --labels=cloudidentity.googleapis.com/groups.discussion_forum
gcloud identity groups create checkout@thecloudgeek.io \
  --organization=thecloudgeek.io --group-display-name="Checkout" \
  --labels=cloudidentity.googleapis.com/groups.discussion_forum

gcloud identity groups memberships add \
  --group-email=gke-security-groups@thecloudgeek.io \
  --member-email=payments@thecloudgeek.io
gcloud identity groups memberships add \
  --group-email=gke-security-groups@thecloudgeek.io \
  --member-email=checkout@thecloudgeek.io
```

Then, in the Admin console, set **View Members** for *Group Members* on the
umbrella group **and on each team group**. Without it GKE cannot resolve
membership at all, and the failure is indistinguishable from the
`authenticator_groups_config` block being absent — you will re-read Terraform
that is already correct. Group changes are cached for a few minutes plus
roughly an hour of credential caching, so do not read a fresh failure as a
broken binding.

**B. `0-foundation` — the M2 identity and API surface.** Uncomment
`gke_security_group` in `terraform.tfvars` now that the group exists, then
apply. This adds the Crossplane provider Google service account, its five
Workload Identity bindings, its project roles (including the conditioned
`projectIamAdmin`), `roles/container.clusterViewer` for the umbrella group, and
the `sqladmin` / `servicenetworking` APIs.

**C. `1-network` — Private Services Access. Do not skip this even though
`1-network` is a persistent layer.** Two independent reasons: `psa.tf` is what
a private-IP Cloud SQL instance needs (without it a `DatabaseInstance` sits in
a `NETWORK_NOT_PEERED` retry loop rather than failing loudly), and this layer
is where `gke_security_group` is *re-published* to `2-cluster`. `cycle.sh`
only ever rebuilds `2-cluster` and `3-argocd`, so setting the group in
foundation and skipping this apply leaves the cluster with no group RBAC and
no error anywhere.

**D. Rebuild the cluster.** `./scripts/cycle.sh down` then
`./scripts/cycle.sh up`. The rebuild is what picks up
`authenticator_groups_config` and the Argo CD XR health checks. `up` now waits
up to `SYNC_TIMEOUT_SECONDS` (2400) because a Cloud SQL create and the GRANT
Job are on the critical path.

**E. Re-advertise the tailnet routes.** The PSA range is a fourth entry in
`private_ranges` and an already-joined jump box does not pick it up:

```
gcloud compute ssh platform-factory-ref-jumpbox --tunnel-through-iap --zone us-central1-a
# on the box, run this layer's output verbatim:
terraform -chdir=layers/1-network output -raw jumpbox_tailscale_up_command
```

Then **approve the new `10.60.0.0/16` subnet route in the Tailscale admin
console**. Advertising is not enough; peers cannot use it until it is approved.

**F. Push the `svc-hello` image — and only now.** The Artifact Registry
repository it pushes to (`.../platform-factory-ref/svc-hello`) is created by
the System Composition, so it does not exist until the `systems` Application
has synced `tenants/svc-hello.yaml`. From the `svc-hello` clone:

```
make login        # once per laptop
make push         # build + push, tagged with the current commit
make set-image    # rewrite k8s/deployment.yaml to that tag
git commit -am 'svc-hello: pin image to <sha>' && git push
```

The manifest ships with the tag `REPLACE_ME` on purpose, so an unpushed
checkout cannot be mistaken for a deployable one; the PR check fails if
`REPLACE_ME` ever reaches `main`.

> **This step is inside a genuine circular dependency, and the first `up` is
> expected to time out because of it.** `cycle.sh up` waits for *every*
> `Application` in `argocd` to be `Synced`/`Healthy`, and the tenant's own
> `Application` — created by the System Composition, so it appears only after
> wave 4 — cannot be Healthy while its `Deployment` is pulling `REPLACE_ME`.
> But the registry it pushes to does not exist until that same wave has run.
> There is no ordering that avoids this on a green-field project; the loop is
> broken by hand, once.
>
> So treat the first M2 bring-up as a bring-up, not as a measured C-02 cycle:
> run `up`, let it converge as far as the tenant Application, push the image
> and commit the tag, then re-run `./scripts/cycle.sh up` (it is idempotent
> against a running cluster) and take *that* as cycle 1. Every later cycle
> starts with the tag already on `main`, so the loop never recurs. Expect the
> abandoned first attempt to record a `verify` row naming
> `svc-hello(sync=Synced health=Progressing)` — that row is the evidence of
> this step, not a regression.
>
> A second, smaller wait sits behind the same Application even once the image
> is pushed: `svc-hello`'s readiness probe checks the database, so the
> `Deployment` stays Progressing until the Cloud SQL instance is up and the
> GRANT Job has completed. That is why the manifest sets
> `progressDeadlineSeconds: 3600` and why `SYNC_TIMEOUT_SECONDS` defaults to
> 2400. If a cold Cloud SQL create ever pushes past that, raise the
> environment variable rather than shortening the probe.

**G. Park between sessions.** From the first Database claim onward,
`./scripts/cycle.sh park` after every `down`. It sets `activationPolicy: NEVER`
on every Cloud SQL instance labelled `system`, which is the only running cost
a `down` does not remove. Forgetting costs money, not correctness, and the
results file records whether it ran.

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

**Evolution note:** nodes are private (`2-cluster`) and egress through Cloud
NAT, which lives here in `1-network/nat.tf` — it moved out of `2-cluster` on
2026-08-20 when the jump box arrived, because a subnet's ranges can only be
covered by one NAT gateway and the jump box needs egress on the cluster's off
days. NAT today allows all outbound traffic indiscriminately; FQDN-based
egress restriction on top of it arrives with the fuller M3 egress-control
work. This VPN section covers only the inbound site-to-site connection, and
ADR-0011 superseded it for user access — `enable_vpn` stays false and the
tailnet carries that traffic instead.

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
./scripts/cycle.sh park        # stop the paved road's Cloud SQL instances
./scripts/cycle.sh status      # what's live right now
```

(`park` is the M2 addition and has nothing to do with the rebuild — see
*Durable resources and the rebuild* below. The three things below are about
`down`, `up` and `cycle`.)

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
   After both applies it fetches cluster credentials and waits for *every*
   Argo CD Application — the root and each child it creates from
   `platform-config` — to report `Synced`/`Healthy`. Every one, not just
   the root: Argo CD stopped counting child Applications toward a parent's
   health in 1.8, so a root-only check can pass while Crossplane underneath
   it is still failing.

Each phase is appended to `scripts/cycle-results.tsv` (timestamp, cycle,
phase, layer, seconds, exit code, note) — wall-clock down and up, per layer,
across every run. That file is the evidence, so it's committed rather than
gitignored. Since M2 it also carries an `up`/`durable` row per rebuild and a
`park` row per instance; both are explained below.

Cycle numbers come from that file, not from you: `down` opens cycle
*last + 1*, `up` continues the last cycle if it has a `down` but no `up`
yet (so a teardown one evening and a rebuild the next morning are one
cycle, and re-running `up` after a failure stays in the same cycle), and
`cycle N` numbers each pass consecutively from there. `park` doesn't claim a
number of its own — it records against the cycle most recently opened,
because it's an operator action *between* cycles and a new number would
inflate the count. Don't edit the numbers by hand.

> **Note:** `root_app_automated_sync` defaults to `true` (since 2026-08-13).
> With it `false`, a rebuilt root Application sits `OutOfSync` until someone
> syncs it by hand and the verify step fails by design rather than wait it
> out — which is the honest result, since "rebuilt without manual steps" can
> only be claimed under automated sync.

### Durable resources and the rebuild (M2, ADR-0015)

Through M1, "rebuild from empty" was literally true: nothing running in the
cluster had created anything outside it, so a teardown left a clean slate and
a rebuild built onto one. M2 ends that. The paved road's whole purpose is that
a merged claim creates something real in the cloud — a Cloud SQL instance, an
Artifact Registry repository — and the platform's promise is that deleting the
claim does **not** delete the database. Anything with that property also
survives `cycle.sh down`, so on the way back up the platform meets its own
leftovers. Three rules, all of them in the script:

1. **`down` does not delete durable resources, and must never learn to.**
   Today it can't even by accident — a cluster destroy is not a Kubernetes
   delete, and the root Application carries no cascade-delete finalizer — but
   that's an accident of construction, not a policy, so ADR-0015 makes it one.
   Removing a database for real is a deliberate `gcloud` command run by a
   human after the claim is gone, recorded as such. The platform offers no
   automation for it, because a wrong number on a bill is recoverable and a
   wrong delete is not.

2. **`up` proves the rebuild *adopted* what was there rather than assuming
   it.** Crossplane re-imports an existing cloud resource by its
   `crossplane.io/external-name` annotation, which the Compositions derive
   from the claim (`<system>` for a registry repository, `<system>-<claim>`
   for an instance) precisely so a rebuild lands on the same name. But a
   rebuild that *failed* to adopt — one that quietly stood up a fresh, empty
   database next to the old one — would still reach 100% Applications
   Synced/Healthy and get written into `cycle-results.tsv` as a clean cycle.
   So `up` asks each durable resource when GCP created it and writes one more
   row: `up / durable`, with every name stamped as
   `<kind>/<name>@<createTime>` so the row can be re-read months later
   without re-querying GCP. Four buckets, and the difference between them is
   the whole point:

   | Bucket | Means | Row |
   |---|---|---|
   | `adopted` | created before this `up` started — the external-name import worked | green |
   | `new` | created during this `up`, and a name this file has never recorded | green — a tenant's first provision is not a failure |
   | `recreated` | created during this `up`, but this file has seen the name before | **red**, unless `EXPECT_FRESH=1` |
   | `unknown` | the createTime wasn't parseable, so the check answered nothing | **red** — a check that told you nothing must not read as a pass |

   The results file is its own prior: that's what separates "the rebuild
   failed to adopt" from "this had never been created before", which a
   timestamp compare alone cannot tell apart. The one case it can't infer is
   ADR-0015 §6's deliberate-delete rebuild, where re-creating a name we've
   seen is the expected result — run that one as
   `EXPECT_FRESH=1 ./scripts/cycle.sh up` and the row records the
   expectation instead of a false finding.

   On the happy path the check runs once every Application is Healthy,
   because before then Crossplane hasn't finished reconciling. It *also*
   runs when the verify step times out, marked `partial` — a rebuild that
   blew the timeout while creating a fresh instance from scratch is exactly
   the case the evidence exists for, so it's the last cycle that should
   record silence.

   Coverage is two of ADR-0015 §1's three durable kinds. The composed
   `Database` (`app`) has no cloud-side creation timestamp to ask for — the
   Cloud SQL API's database resource simply doesn't carry one — so it rides
   on the instance: Crossplane observes a database inside an instance it
   didn't re-create, so an adopted instance means an adopted database.

   With no tenants yet it records zeroes and changes nothing — that's the
   shape cycles 1–4 in the results file already have. A zero is only allowed
   to be quiet when it's true: if `System`s or `Database` claims exist and
   nothing in the cloud carries the label, the row goes red and names the
   Composition field that stopped being set, because at that point both this
   check and `park` have gone blind rather than found nothing.

3. **Idle cost is handled by stopping, not deleting — `./scripts/cycle.sh
   park`.** It sets Cloud SQL's activation policy to `NEVER` on every instance
   the paved road created, which suspends the instance charge; storage and the
   reserved private IP keep billing, and that's the honest price of keeping
   the data. It is a separate command on purpose rather than a step inside
   `down`: `cycle.sh`'s number is rebuild wall-clock, and folding cost hygiene
   into the measured path would change that number and hide the choice. The
   known failure mode is that someone forgets to run it; the results file
   shows whether they did.

Both `park` and the adoption check find their subjects by the `system` label
the Compositions put on every cloud resource, never by a hand-kept list — the
same label that makes "did the platform create this?" an auditable question
afterwards. That's a contract with `platform-config`, so both sides say so
when it breaks rather than reporting a tidy zero: `park` re-lists without the
filter and warns if unlabelled instances are sitting there billing. That's also what keeps layer 0's own Artifact Registry remotes
(`docker-hub`, `ghcr-io`, …) out of scope: they're Terraform's, they predate
every System, and they carry no such label. Both reach those resources through
`gcloud`, never Terraform, so the script's "only `2-cluster` and `3-argocd`"
assertion is untouched and still covers every `terraform` call it can make.

Nothing unparks on the way back up, and nothing needs to: the Composition
declares `activationPolicy: ALWAYS` and holds the `Update` management policy,
so Crossplane sees a parked instance as drift and starts it again. The same
mechanism is why `park` can be run at any time but only *sticks* while the
cluster is down.

> **This changes what a cycle time means.** From the first `Database` claim
> on, `up` includes an instance restart and adoption on the critical path, so
> those timings are not comparable to M1's — the same caveat that applied when
> Cloud NAT moved layers. The `up / durable` row is where the difference shows
> up rather than quietly inflating the `up / TOTAL` number. It also moves the
> verify timeout: `SYNC_TIMEOUT_SECONDS` defaults to 2400 rather than M1's
> 900, because nothing goes `Healthy` until Cloud SQL itself reports ready
> and the grant job completes. A timeout here isn't a soft failure — it kills
> the run and gets counted as a C-02 manual intervention — so a number too
> small would manufacture failures out of slow but correct rebuilds.

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
Cloud NAT, a regional control plane, a control-plane endpoint that is
identity-gated rather than address-gated (the GKE DNS-based endpoint, per
ADR-0011 — the `authorized_networks` allowlist was removed, not tightened),
on-demand (not Spot) nodes, and a Tailscale subnet router for private-range
access.

- **Image plane (ADR-0010).** All image pulls — Argo CD's own image, dex,
  redis, and (since `platform-config`'s app-of-apps landed) Crossplane's
  three component images and its provider packages — go through Artifact
  Registry remote repositories (`0-foundation/registry.tf`) over Private
  Google Access, not the public internet. Crossplane's package manager pulls
  with its own pod identity rather than the node's, so `0-foundation/iam.tf`
  grants `artifactregistry.reader` to its Kubernetes service account
  directly through Workload Identity — no pull secret, no key. That leaves exactly one internet egress path for the cluster:
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
| Cloud NAT | `1-network/nat.tf` | It serves the whole subnet, not just nodes — the jump box needs egress on days the cluster doesn't exist, and two gateways can't cover the same ranges, so it persists. Exists because nodes are private (ADR-0009's corp-real posture); as of ADR-0010 its only real cluster-side consumer is Argo CD's git egress to GitHub, since images no longer need it. |
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

This repo is built out in **M1** and extended in **M2**.

## Status

**Status:** M2 — the layer changes are authored and `terraform validate`-clean,
and **not yet applied**. What M2 adds here: the Crossplane provider Google
service account with its five Workload Identity bindings and its project roles
(`0-foundation/iam.tf`), the `sqladmin` and `servicenetworking` APIs
(`0-foundation/main.tf`), Private Services Access for private-IP Cloud SQL
(`1-network/psa.tf`), `authenticator_groups_config` on the cluster
(`2-cluster/gke.tf`), Argo CD health checks for the two XR kinds
(`3-argocd/argocd.tf`), and `cycle.sh park` plus the durable-resource adoption
check. The operator order for all of it is **Runbook step 5** above; the
layer-1 apply in that list is a C-01 crossing on a persistent layer and should
be counted as such.

Everything below is M1 and has been exercised.

**M1:** All four layers are written, `terraform
validate`-clean (`1-network` validated with `enable_vpn` both true and false),
and **applied against real infrastructure** — `0-foundation` and `1-network`
have been live since 2026-08-06 and persist by design, while `2-cluster` and
`3-argocd` are destroyed and rebuilt between sessions by `scripts/cycle.sh`
(measured times per phase in `scripts/cycle-results.tsv`). Corp-real posture
(private nodes, Cloud NAT, regional control plane, on-demand nodes) applied per
ADR-0009; control-plane access is identity-gated via the GKE DNS-based endpoint
rather than an IP allowlist, per ADR-0011, with a Tailscale subnet router on the
jump box carrying private-range access. Image plane moved to Artifact Registry
remote repositories per ADR-0010 and verified live — a forced pull of a
never-cached image resolved to a `*.pkg.dev` digest while Cloud NAT logged no
registry egress at all.

**M1 closed 2026-08-28.** `cycle-results.tsv` holds the three scripted cycles
C-02 asks for; cycles 2 and 3 ran at **zero manual interventions**, and the
`2-cluster` rebuild came in at 753s / 755s / 755s across the three. The
app-of-apps in `platform-config` reached 3/3 Applications Synced/Healthy from
an empty cluster with no manual ordering, and every image on it — Crossplane,
its six GCP provider packages, and Argo CD's own — arrived through Artifact
Registry with zero registry egress in the NAT logs. Grades and the evidence
behind them are in the design-seed repo's build log (`docs/build-log/`).
