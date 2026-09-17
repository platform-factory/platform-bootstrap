resource "google_container_cluster" "primary" {
  name = var.cluster_name

  # Regional, not zonal: a normal corp environment runs a regional control
  # plane (ADR-0009 — mock a real corp environment over cost). location
  # matching a region string (vs a zone string) is what makes this
  # regional; node_locations below controls which zones within it actually
  # get nodes.
  location       = data.terraform_remote_state.network.outputs.region
  node_locations = var.node_locations

  # By name, not by resource reference — the VPC and subnet live in
  # 1-network's state, a persistent layer this one gets torn down and
  # rebuilt independently of (see README). google_container_cluster accepts
  # a plain network/subnet name, so no data-source lookup is needed beyond
  # the remote_state read already happening for provider config.
  network    = data.terraform_remote_state.network.outputs.network_name
  subnetwork = data.terraform_remote_state.network.outputs.subnet_name

  # The default node pool can't be configured the way we want (machine
  # type, spot, autoscaling), so it's removed immediately and replaced by
  # the dedicated google_container_node_pool below. initial_node_count = 1
  # here is just the transient default pool's size before removal.
  initial_node_count       = 1
  remove_default_node_pool = true

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = data.terraform_remote_state.network.outputs.pods_range_name
    services_secondary_range_name = data.terraform_remote_state.network.outputs.services_range_name
  }

  # Private nodes (no public IPs) is the other half of the corp-real
  # posture, alongside the regional control plane above. Nodes reach
  # Google APIs via private_ip_google_access on the subnet (1-network) and
  # the internet via Cloud NAT, which lives in 1-network as of ADR-0011 — it
  # moved out of this layer when the jump box gave it a second consumer on a
  # persistent schedule, and a persistent resource cannot depend on a
  # disposable one.
  #
  # enable_private_endpoint = true is NOT a leftover from the pre-ADR-0011
  # posture — it is what GKE itself reports once control_plane_endpoints_config
  # below disables the IP endpoints, and it has to be stated here to match.
  # Left at the old `false`, the very next plan reads `true -> false`, and
  # applying it would REOPEN the public IP endpoint, silently undoing the
  # identity-gated posture. Caught on 2026-08-20 in the plan that moved NAT
  # out of this layer; see the build log. ip_endpoints_config is the
  # authoritative control — this flag only agrees with it, and reachability
  # is the DNS endpoint only.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  # Control plane access is identity-gated, not location-gated. The
  # DNS-based endpoint is a public name resolved through Google's API front
  # door and authorized by IAM, so it works from any network with no
  # tunnel, no bastion, and no allowlist entry. Google names it the
  # preferred control plane access path.
  #
  # This is also the bootstrap path. 3-argocd needs Helm access to the API
  # server before anything exists in the cluster, so the control plane has
  # to be reachable before the in-cluster access plane (Tailscale operator)
  # is installed. A tailnet whose subnet router lives in the cluster cannot
  # bootstrap itself.
  #
  # Replaces master_authorized_networks_config, which used to gate a public
  # IP endpoint by source address. Pinning the operator's dynamic residential
  # /32 broke access twice in five days and killed a cycle.sh run mid-flight;
  # ADR-0011 has the full reasoning, including why finishing the site-to-site
  # VPN would have made that worse rather than better.
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }

    # The IP endpoints are off, so this cluster has exactly one way in and
    # it is identity-gated. Verified reachable over DNS before this was
    # flipped (kubectl get nodes, and 3-argocd refreshing both helm
    # releases) — the ordering matters, because turning this off while the
    # DNS path was unproven would have locked the operator out.
    ip_endpoints_config {
      enabled = false
    }
  }


  # Kubernetes service accounts impersonate GCP service accounts through
  # this pool instead of nodes carrying long-lived service account keys.
  workload_identity_config {
    workload_pool = "${data.terraform_remote_state.network.outputs.project_id}.svc.id.goog"
  }

  # Google Groups for RBAC. This is what lets a RoleBinding name a Google
  # Group as its subject and have GKE actually resolve the caller's
  # membership — without it, a binding on payments@thecloudgeek.io matches
  # nobody and the whole ADR-0012 tenancy model has no enforcement point.
  #
  # GKE resolves membership ONLY for groups nested under one umbrella group,
  # and the umbrella group's local part is not a convention, it is a
  # requirement: it must be named exactly `gke-security-groups` in the
  # domain. Verified 2026-09-16 against docs.cloud.google.com/
  # kubernetes-engine/docs/how-to/google-groups-rbac ("Create a group in
  # your domain named gke-security-groups. The gke-security-groups name is
  # required.") and against the provider schema's own description, which
  # repeats the format.
  #
  # Two consequences worth carrying forward, both from the same doc:
  #   - Team groups are NESTED INSIDE the umbrella group. Individual users
  #     are not added to it directly. GKE checks that the group granting
  #     access is itself nested under gke-security-groups.
  #   - The group names in RoleBindings are CASE-SENSITIVE, so the System
  #     Composition's <team>@thecloudgeek.io must match the Workspace group
  #     exactly.
  #
  # MANUAL PREREQUISITES ON THE WORKSPACE SIDE, from the same doc, because
  # getting them wrong produces a failure INDISTINGUISHABLE from this block
  # being absent — the RoleBinding simply matches nobody, and the operator
  # comes back here to re-read Terraform that is already correct:
  #   - The umbrella group AND every nested team group must have the "View
  #     Members" permission selected for Group Members, or GKE cannot
  #     enumerate membership at all. Quoted from the doc: "Make sure the
  #     group has the View Members permission selected for Group Members" and
  #     "Each group must have the View members permission for Group members."
  #   - Changes take time to land. "Information about Google Groups
  #     membership is cached for a short time. It might take a few minutes
  #     for changes in group memberships to propagate to all your clusters.
  #     In addition to latency from group changes, standard caching of user
  #     credentials on the cluster is about one hour." So after fixing a
  #     group, re-test an hour later before concluding the binding is wrong —
  #     otherwise the second fix gets applied to a problem that was already
  #     solved.
  #
  # WHY THE DYNAMIC BLOCK. Creating Workspace groups is a manual admin task
  # outside the paved road (ADR-0012 §3), and at the time this was written
  # it was not yet confirmed that any of the groups exist. A hardcoded
  # group email would make this layer un-appliable until someone finished
  # an errand in the Admin console; with the passthrough null, this block
  # renders nothing and the cluster is exactly the M1 cluster. That keeps
  # the "bundle every M2 change into one apply per layer" plan achievable
  # rather than blocked on a dependency Terraform cannot create.
  #
  # C-06 EVIDENCE. This is the cluster-side half of "ownership moves
  # without re-plumbing": with group RBAC resolving, moving svc-hello
  # between teams is a one-line change to spec.owner.team and the
  # Composition rebinds the group. Without it, the move would have to
  # re-plumb individual user bindings, which is what the claim says should
  # not be necessary.
  #
  # C-01 COUNTER, stated honestly: this is a Terraform change to a
  # disposable layer, so it arrives on the next rebuild rather than as a
  # standalone apply — but it is still one of the four crossings the M2
  # readiness walk predicted, and it is counted as such. It is bundled with
  # nothing else in this layer precisely so the crossing is one per layer
  # rather than one per discovery.
  #
  # GOTCHA FOR LATER: the provider marks this attribute Computed, so
  # DELETING the block does not turn the feature off — Terraform keeps the
  # last value it read. Disabling group RBAC needs an out-of-band change
  # (`gcloud container clusters update ... --security-group=""`), not a
  # config deletion. Adding it, by contrast, is an in-place update and does
  # not recreate the cluster (no ForceNew on the schema; the provider has an
  # explicit DesiredAuthenticatorGroupsConfig update path) — irrelevant here
  # because this layer is rebuilt, but worth knowing before anyone panics
  # at a plan.
  dynamic "authenticator_groups_config" {
    for_each = local.gke_security_group == null ? [] : [local.gke_security_group]

    content {
      security_group = authenticator_groups_config.value
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  # Teardown between working sessions is the cost-control move for this
  # layer (see README) — deletion_protection = true (the provider default)
  # would block exactly that. Unchanged by the corp-real posture work above:
  # the teardown rhythm is what keeps the regional control plane's cost
  # small in practice, so it stays.
  deletion_protection = false
}

resource "google_container_node_pool" "primary" {
  name    = "primary"
  cluster = google_container_cluster.primary.name
  # No explicit location: a regional node pool in the same module as its
  # cluster inherits the cluster's own node_locations rather than needing
  # it repeated here.

  # PER ZONE, not cluster-total — see the var descriptions in variables.tf.
  initial_node_count = var.node_count_initial

  autoscaling {
    min_node_count = var.node_count_min
    max_node_count = var.node_count_max
  }

  node_config {
    machine_type = var.machine_type

    # The dedicated node identity from 0-foundation/iam.tf — not the
    # default Compute Engine service account. That SA carries exactly
    # roles/container.defaultNodeServiceAccount (logging/monitoring/
    # autoscaling metrics) and roles/artifactregistry.reader (ADR-0010
    # image pulls); see iam.tf for why the default SA isn't good enough
    # here (org policy can leave it with no roles at all).
    service_account = data.terraform_remote_state.network.outputs.gke_node_service_account_email

    # On-demand by default (var.use_spot_nodes = false) — corp-real per
    # ADR-0009, not optimized for minimum cost. See the variable's
    # description for the trade-off if you flip it.
    spot = var.use_spot_nodes

    # Shielded VM: secure boot + integrity monitoring, the other standard
    # corp-baseline node setting alongside private nodes and shielded
    # instances being GKE's own default recommendation, not something
    # specific to this build.
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # Scope stays broad (cloud-platform) rather than narrowed — safe now
    # for two separate reasons, not one: workload identity (above) is what
    # actually gates pod-level GCP access, since pods don't inherit the
    # node's scope; and for the node's OWN access, the real ceiling is
    # service_account's IAM roles above, not this OAuth scope — a broad
    # scope on a least-privilege service account can't grant more than
    # that service account actually has.
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }
}
