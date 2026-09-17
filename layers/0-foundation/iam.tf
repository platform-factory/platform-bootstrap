# A dedicated least-privilege node service account instead of the default
# Compute Engine service account. Two independent problems converge on the
# same fix:
#   - Private nodes (2-cluster) pulling from the ADR-0010 Artifact Registry
#     remote repos need artifactregistry.reader; the default SA doesn't
#     have it.
#   - This project is created under a Google Workspace org (var.org_id).
#     Orgs created on or after 2024-05-03 enforce the
#     iam.automaticIamGrantsForDefaultServiceAccounts organization policy
#     constraint by default, which stops the default Compute Engine SA from
#     automatically getting any project role at all — so on this org, that
#     SA can have NO permissions, and nodes fail logging, monitoring, and
#     image pulls on first boot regardless of the Artifact Registry
#     question above.
#
# Lives in foundation, not 2-cluster: identity persists, compute is
# disposable — the same boundary rule as everything else in this repo —
# and it avoids recreating (and re-propagating IAM for) the service
# account on every teardown/rebuild cycle.
#
# Role list verified 2026-08-06 against Google's current GKE
# node-service-account guidance:
#   - docs.cloud.google.com/kubernetes-engine/security/configure-node-service-accounts
#   - docs.cloud.google.com/kubernetes-engine/docs/how-to/hardening-your-cluster
# This corrects an older, still widely-repeated pattern of granting four
# separate roles (logging.logWriter, monitoring.metricWriter,
# monitoring.viewer, stackdriver.resourceMetadata.writer). Google's CURRENT
# official Terraform example for this exact task grants exactly one
# consolidated predefined role instead:
#
#   resource "google_service_account" "default" { ... }
#   resource "google_project_iam_member" "default" {
#     role   = "roles/container.defaultNodeServiceAccount"
#     member = "serviceAccount:${google_service_account.default.email}"
#   }
#
# That same doc page's Config Connector tab (a different tool, shown as an
# alternative to the Terraform tab above, not an addition to it) grants the
# equivalent access as four roles — logging.logWriter, monitoring.metricWriter,
# monitoring.viewer, autoscaling.metricsWriter — confirming
# defaultNodeServiceAccount already bundles those four, autoscaling metrics
# included (this cluster runs the node-count autoscaler, so that coverage
# matters). Note the fourth role there is autoscaling.metricsWriter, not
# stackdriver.resourceMetadata.writer — that role does not appear anywhere
# in either current doc page and was not carried forward here.
resource "google_service_account" "gke_nodes" {
  project      = google_project.this.project_id
  account_id   = "gke-nodes"
  display_name = "GKE node identity (2-cluster) — deliberately not the default Compute Engine service account"
}

resource "google_project_iam_member" "gke_nodes_default" {
  project = google_project.this.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# ADR-0010: lets nodes pull from the remote-repo image caches in
# registry.tf. Google's own docs grant this role per-repository rather
# than project-wide (tighter scope); this binds it at the project instead
# — six separate per-repository bindings for six remotes was judged more
# indirection than this reference build's blast radius justifies, though
# per-repository is the more correct production pattern if this SA ever
# needs to NOT read one of the six.
#
# Both bindings on this page are additive (google_project_iam_member),
# never authoritative (google_project_iam_policy / google_project_iam_binding)
# — those replace the entire project policy for the role, which would
# clobber the org's own bindings and GKE's own service-agent bindings on
# this project, not just add to them.
resource "google_project_iam_member" "gke_nodes_artifact_registry" {
  project = google_project.this.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# Crossplane's package manager pulls provider packages itself — from its
# own pod, with its own identity — not through kubelet, so the node service
# account above does nothing for it. Its fetcher (crossplane-runtime
# pkg/xpkg/fetch.go, verified 2026-08-27) authenticates through
# go-containerregistry's k8schain, which includes the Google keychain: on a
# Workload Identity cluster (2-cluster) that resolves to the pod's own
# Kubernetes service account as a federated principal. This binding grants
# that principal read access to the Artifact Registry remotes, so the
# ImageConfig mirror rule in platform-config actually pulls — no pull
# secret, no Google service account, no key anywhere.
#
# The principal identifier format is Google's documented Workload Identity
# Federation for GKE form (kubernetes-engine/docs/how-to/workload-identity,
# "Authenticate to Google Cloud APIs from GKE workloads", verified
# 2026-08-27). The namespace and service account name are the Crossplane
# chart's defaults: crossplane-system / crossplane. If either changes in
# platform-config, this binding has to change with it — the coupling is the
# price of not shipping a credential.
#
# Lives in foundation for the same reason the node identity does: identity
# persists, and this survives every teardown/rebuild cycle unchanged.
resource "google_project_iam_member" "crossplane_artifact_registry" {
  project = google_project.this.project_id
  role    = "roles/artifactregistry.reader"
  member  = "principal://iam.googleapis.com/projects/${google_project.this.number}/locations/global/workloadIdentityPools/${google_project.this.project_id}.svc.id.goog/subject/ns/crossplane-system/sa/crossplane"
}

# ---------------------------------------------------------------------------
# M2: the cloud identity the Crossplane PROVIDERS run as.
# ---------------------------------------------------------------------------
#
# Read the binding above this one first, because the contrast is the point.
# Two different Crossplane workloads need Google credentials and they use two
# DIFFERENT federation flows on purpose:
#
#   - Crossplane CORE pulls provider packages. Its fetcher authenticates
#     through go-containerregistry's Google keychain, which accepts the
#     DIRECT federated principal — `principal://...workloadIdentityPools/
#     <project>.svc.id.goog/subject/ns/<ns>/sa/<ksa>` — so there is no Google
#     service account in that path at all (see crossplane_artifact_registry
#     above). Nothing to create, nothing to key, nothing to rotate.
#
#   - The PROVIDER pods create cloud resources through the GCP APIs, driven
#     by a ProviderConfig whose credentials source is `InjectedIdentity`.
#     provider-upjet-gcp v3.0.0 documents exactly ONE keyless path for this
#     (docs/family/Configuration.md, read 2026-09-02 during the M2 readiness
#     walk, re-confirmed against the v3.0.0 tree 2026-09-16): a Google
#     service account, a roles/iam.workloadIdentityUser binding from the
#     provider pod's Kubernetes service account, and the
#     iam.gke.io/gcp-service-account annotation on that Kubernetes service
#     account. That is the impersonation flow, and it is what the resources
#     below implement.
#
# Two flows in one file looks inconsistent, so: it is deliberate, and the
# reason is that the direct form was never confirmed to work for
# `InjectedIdentity`. The v3.0.0 docs describe only the impersonation form;
# whether the provider's credential chain would also accept the direct
# principal is UNVERIFIED and deliberately NOT tested here — proving it would
# have meant debugging a keyless-auth failure inside a provider pod on the
# critical path of the M2 floor apply. ADR-0013 §1 records the assumption.
# If someone later shows the direct form works, everything below collapses
# to five IAM bindings and this service account disappears.
#
# ONE service account for all five service providers, not one each. Per-
# provider identities would be the tighter design in the abstract — the SQL
# provider has no business creating Artifact Registry repositories — but they
# would be five service accounts and five sets of role bindings to keep in
# sync, and the isolation is weaker than it looks: any Composition in
# platform-config can already compose kinds across all five providers, so a
# mistake in a Composition reaches the same cloud surface either way. One
# identity, and the roles below are the honest statement of what the platform
# can do. ADR-0013 §6 and the readiness walk's "floor" both assume it.
# Splitting it later is a mechanical change: five service accounts, this
# for_each becomes a map, and each provider's roles narrow.
#
# Lives in foundation for the same reason as everything else on this page:
# identity persists, compute is disposable. The cluster is rebuilt every
# cycle; this service account and its bindings are not.
resource "google_service_account" "crossplane_provider" {
  project = google_project.this.project_id

  # account_id is constrained by GCP to 6-30 characters, lowercase letters,
  # digits and hyphens (iam/docs/service-accounts-create, checked
  # 2026-09-16). "crossplane-provider-gcp" is 23.
  account_id = "crossplane-provider-gcp"

  # display_name is capped at 100 UTF-8 BYTES, not characters
  # (iam/docs/reference/rest/v1/projects.serviceAccounts, fetched 2026-09-16:
  # "The maximum length is 100 UTF-8 bytes"). The provider ships no client-side
  # validator for this field, so an over-long name passes `terraform validate`
  # and `plan` and fails at apply with a 400 — which, because this is the first
  # resource of the M2 identity block, takes the five Workload Identity
  # bindings and four role bindings down with it. Budget the em dash at 3 bytes
  # and § at 2 when counting: the first draft of this string was 104 characters
  # but 107 bytes. The impersonation detail lives in the comment above instead.
  display_name = "Crossplane GCP provider identity (ADR-0013 §6)"
}

# The five service providers installed in platform-config. Each provider pod
# runs as its OWN Kubernetes service account in crossplane-system, and each
# one needs its own workloadIdentityUser binding on the single Google service
# account above — the binding names an exact KSA, so there is no wildcard
# that covers all five.
#
# These names are NOT accidental and NOT chosen by Crossplane. By default the
# package manager names a provider's KSA after its ProviderRevision, which
# changes on every provider version bump — and a binding to a name that
# changes is a binding that breaks on every upgrade. platform-config pins
# each one with a DeploymentRuntimeConfig
# (spec.serviceAccountTemplate.metadata.name), which is the documented way to
# override the generated name (docs.crossplane.io/v2.3/packages/providers,
# read 2026-09-16). So this list and the DeploymentRuntimeConfig names in
# platform-config are one coupling with two ends: change one, change both, or
# the provider loses its credentials silently and every managed resource
# fails with a 403 that does not say why.
#
# Note also that Crossplane's package manager CREATES and OWNS those
# Kubernetes service accounts. platform-config must not also create them, and
# the same name must never be given to two packages (documented as a common
# mistake that causes reconciliation loops). Our half of the deal is only the
# Google-side binding below.
locals {
  crossplane_provider_ksas = [
    "provider-gcp-storage",
    "provider-gcp-sql",
    "provider-gcp-cloudplatform",
    "provider-gcp-artifact",
    "provider-gcp-dns",
  ]
}

# Both halves of Workload Identity are required and only one of them is here.
# Google's own words (kubernetes-engine/docs/how-to/workload-identity,
# "Authenticate to Google Cloud APIs from GKE workloads"): "Both the IAM allow
# policy and the annotation are required when you use this method." This
# resource is the allow policy; the iam.gke.io/gcp-service-account annotation
# on each Kubernetes service account is the DeploymentRuntimeConfig's job, in
# platform-config. Half of this configured is the same as none of it.
#
# The member string's pool is always "<PROJECT_ID>.svc.id.goog" — the project
# ID, not the project number — which is exactly what 2-cluster passes as
# workload_identity_config.workload_pool.
resource "google_service_account_iam_member" "crossplane_provider_workload_identity" {
  for_each = toset(local.crossplane_provider_ksas)

  # .name is the fully-qualified "projects/<p>/serviceAccounts/<email>" form
  # the API wants, and using the attribute (rather than hardcoding the string)
  # is what creates the dependency edge so the service account exists first.
  service_account_id = google_service_account.crossplane_provider.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${google_project.this.project_id}.svc.id.goog[crossplane-system/${each.value}]"
}

# The provider identity's project roles. Every one of these exists because a
# Composition in platform-config creates a kind that needs it — the roles
# accrete per claim, exactly as the M2 readiness walk predicted, and this is
# the whole accretion in one apply.
#
# Four roles are granted here; a fifth, roles/resourcemanager.projectIamAdmin,
# is in its own block below because its IAM Condition needs the space. All four
# confirmed against docs.cloud.google.com/iam/docs/roles-permissions on
# 2026-09-16:
#
#   artifactregistry.admin      — the System Composition creates a per-system
#                                 DOCKER repository and sets
#                                 roles/artifactregistry.writer on it for the
#                                 team group. Contains both
#                                 artifactregistry.repositories.create and
#                                 .setIamPolicy. Google's own page flags
#                                 granting .create through this role as
#                                 "highly privileged" — see the containment
#                                 note at the bottom of this block.
#   cloudsql.admin              — the Database Composition creates
#                                 DatabaseInstance, Database and User.
#                                 Contains instances.*, databases.* and
#                                 users.* including the IAM user types.
#                                 Lowest grantable level is Project, so it
#                                 cannot be scoped to one instance.
#   iam.serviceAccountAdmin     — the System Composition creates the
#                                 per-system Google service account AND its
#                                 workloadIdentityUser binding. Contains
#                                 iam.serviceAccounts.create and
#                                 iam.serviceAccounts.setIamPolicy, which is
#                                 the one the binding needs.
#   compute.viewer              — read-only, and the odd one out: no
#                                 Composition creates a Compute resource.
#                                 It is here because Google's own Cloud SQL
#                                 instance-creation page lists it as a
#                                 prerequisite alongside Cloud SQL Admin
#                                 (sql/docs/postgres/create-instance, "Before
#                                 you begin", fetched 2026-09-16: "Make sure
#                                 you have the following roles on your user
#                                 account: Cloud SQL Admin / Compute Viewer"),
#                                 and the Database Composition hands the Cloud
#                                 SQL API a reference to a Compute resource —
#                                 settings.ipConfiguration.privateNetwork =
#                                 projects/<p>/global/networks/<vpc>. Whether
#                                 instances.insert actually enforces
#                                 compute.networks.get on the caller for a
#                                 same-project VPC is UNVERIFIED (Cloud SQL's
#                                 own iam-roles page lists no compute
#                                 permission). Granted anyway because the
#                                 failure mode is asymmetric: the instance is
#                                 created by Crossplane, not Terraform, so a
#                                 denial surfaces as a DatabaseInstance stuck
#                                 in an error loop with no failed apply and
#                                 nothing pointing back at this file. A
#                                 read-only role is a cheap way to not spend a
#                                 C-07 timing measurement bisecting IAM.
#
# All four are additive google_project_iam_member, like everything else on
# this page — never google_project_iam_policy or google_project_iam_binding,
# which are authoritative and would clobber the org's and GKE's own bindings
# on this project rather than add to them.
resource "google_project_iam_member" "crossplane_provider_artifact_registry_admin" {
  project = google_project.this.project_id
  role    = "roles/artifactregistry.admin"
  member  = google_service_account.crossplane_provider.member
}

resource "google_project_iam_member" "crossplane_provider_cloudsql_admin" {
  project = google_project.this.project_id
  role    = "roles/cloudsql.admin"
  member  = google_service_account.crossplane_provider.member
}

resource "google_project_iam_member" "crossplane_provider_service_account_admin" {
  project = google_project.this.project_id
  role    = "roles/iam.serviceAccountAdmin"
  member  = google_service_account.crossplane_provider.member
}

resource "google_project_iam_member" "crossplane_provider_compute_viewer" {
  project = google_project.this.project_id
  role    = "roles/compute.viewer"
  member  = google_service_account.crossplane_provider.member
}

# The strong one, and the reason it is survivable.
#
# The System Composition grants roles/cloudsql.client and
# roles/cloudsql.instanceUser at the PROJECT level — to the system's own
# Google service account, and to the owning team's Google group (ADR-0013
# §1/§5). Project-level is not laziness: roles/cloudsql.client's documented
# lowest grantable level IS the project, so there is no instance-scoped
# alternative. Granting a project role means calling
# resourcemanager.projects.setIamPolicy, which means the provider identity
# needs roles/resourcemanager.projectIamAdmin — i.e. the power to hand ANY
# role, including Owner, to ANY principal on this project.
#
# The condition bounds that to exactly two roles. Verified first-hand
# 2026-09-16 against docs.cloud.google.com/iam/docs/setting-limits-on-granting-roles,
# which documents this exact expression shape and names
# roles/resourcemanager.projectIamAdmin as the role to condition for a
# project-scoped limited IAM admin. From that page, four constraints — all
# satisfied here, all quoted because getting any of them wrong silently
# widens the grant:
#
#   1. "You cannot customize the default value for api.getAttribute functions
#      involving iam.googleapis.com/modifiedGrantsByRole. It must be an empty
#      list." Hence the literal [] second argument.
#   2. "You can include up to 10 values in the list of allowed roles. All of
#      these values must be string constants." Two constants here.
#   3. Never join two hasOnly() statements with && or ||: a request that
#      grants both roles at once would fail even though each is individually
#      allowed. One statement, both roles in it.
#   4. "Don't include ... roles with permission names that end in
#      setIamPolicy" or custom roles the admin can edit. cloudsql.client
#      (instances.connect, instances.get) and cloudsql.instanceUser
#      (instances.executeSql, instances.get, instances.login) contain
#      neither, so there is no self-escalation path through the allowed list.
#
# For any request that is NOT a setIamPolicy call the attribute is undefined,
# api.getAttribute returns the default [], and hasOnly([]) is true — so the
# condition never interferes with ordinary reads.
#
# TWO THINGS TO NOT GET WRONG LATER:
#
#   (a) "Conditional role bindings do not override role bindings with no
#       conditions. If a principal is bound to a role, and the role binding
#       does not have a condition, then the principal always has that role."
#       (same page, verbatim). One unconditioned projectIamAdmin binding for
#       this service account ANYWHERE — added by hand in the console, or by a
#       future resource here — silently voids this entire guardrail. This must
#       remain the only projectIamAdmin binding for this identity.
#
#   (b) Terraform treats the role plus the condition's title, description AND
#       expression as the binding's identity. Editing so much as a typo in the
#       description below is a destroy-then-create, briefly leaving the
#       provider without projectIamAdmin mid-apply. Treat this text as
#       immutable once applied.
#
# CONTAINMENT, HONESTLY STATED: this condition limits which roles this
# identity can grant AT THE PROJECT LEVEL. It is not a general containment
# boundary for the provider. The unconditioned artifactregistry.admin binding
# above independently authorizes repository-level setIamPolicy (and Artifact
# Registry does not recognize the modifiedGrantsByRole attribute at all, so it
# could not be conditioned this way even if we wanted);
# iam.serviceAccountAdmin independently authorizes setIamPolicy on any service
# account in the project — including granting token-creator on a more
# privileged one; and cloudsql.admin independently authorizes setIamPolicy on
# Cloud SQL instances and databases (cloudsql.instances.setIamPolicy and
# cloudsql.databases.setIamPolicy are both listed as Cloud SQL Admin / Owner
# only, sql/docs/postgres/iam-roles, fetched 2026-09-16). Three of the four
# unconditioned roles carry their own setIamPolicy power; this list is meant to
# be exhaustive, so if a role is added above, check it here too. Anyone reading
# this condition as "Crossplane is contained"
# is reading it wrong. The real containment for those two roles is the Kyverno
# rule and the RBAC suspender in platform-config (ADR-0014 §3), not IAM.
resource "google_project_iam_member" "crossplane_provider_project_iam_admin" {
  project = google_project.this.project_id
  role    = "roles/resourcemanager.projectIamAdmin"
  member  = google_service_account.crossplane_provider.member

  condition {
    title       = "only-cloudsql-connect-roles"
    description = "Limits this identity to granting or revoking exactly roles/cloudsql.client and roles/cloudsql.instanceUser on the project allow policy."
    expression  = "api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly(['roles/cloudsql.client','roles/cloudsql.instanceUser'])"
  }
}

# ---------------------------------------------------------------------------
# M2: the one cloud IAM grant that tenancy needs (ADR-0012 §5).
# ---------------------------------------------------------------------------
#
# GKE will not even let a human AUTHENTICATE to a cluster without
# container.clusters.get at the project — RBAC is only consulted after that
# hop succeeds. So every team member needs a project-level binding before any
# RoleBinding the System Composition writes can matter.
#
# This grants it ONCE, to the umbrella group, instead of per team from the
# Composition. Two consequences, and both are the point of ADR-0012 §5:
# moving a service between teams touches no cloud IAM at all (which is what
# lets C-06 honestly report "one file touched"), and the Composition never
# needs project-IAM-admin power for tenancy — only for the two Cloud SQL
# roles conditioned above.
#
# roles/container.clusterViewer confirmed 2026-09-16 against
# docs.cloud.google.com/iam/docs/roles-permissions/container. Exactly five
# permissions: container.clusters.connect, container.clusters.get,
# container.clusters.list, resourcemanager.projects.get,
# resourcemanager.projects.list. Note .connect as well as .get — that is what
# `gcloud container clusters get-credentials` needs, and with 2-cluster's
# DNS-endpoint-only, identity-gated control plane it is the whole "day one
# access" story for a team member: this grant gets them a kubeconfig, and
# in-cluster RBAC decides what they can see with it. The group sees NOTHING
# in the cluster until a RoleBinding says otherwise.
#
# UNVERIFIED, and load-bearing: that an IAM binding on `group:` resolves
# members of NESTED groups (the team groups live inside the umbrella group —
# GKE's setup doc requires the nesting and forbids adding individual users to
# gke-security-groups). No single Google sentence states it outright. What is
# documented: each member of a group inherits roles granted to that group, and
# a nested group is a member; Policy Analyzer expands nested groups when
# answering who-has-permission; GKE's own RBAC path explicitly resolves
# nesting and counts nested memberships toward its 2000-group limit. ADR-0012
# §5 records the fallback if it turns out not to hold: the grant moves to a
# per-team ProjectIAMMember in the Composition, and C-06's "re-created" column
# gets an entry. Confirm on the first real login before writing it down as
# settled.
#
# Guarded on the variable because the Google Group may not exist yet —
# creating it is a Workspace-admin task outside Terraform, and a binding to a
# non-existent group fails the apply. Null (the default) creates nothing, so
# the floor apply can land before the groups do.
resource "google_project_iam_member" "gke_security_groups_cluster_viewer" {
  count = var.gke_security_group == null ? 0 : 1

  project = google_project.this.project_id
  role    = "roles/container.clusterViewer"

  # The "group:" prefix is required by the API (and by Terraform); only the
  # Console lets you omit it. iam/docs/principal-identifiers, 2026-09-16.
  member = "group:${var.gke_security_group}"
}
