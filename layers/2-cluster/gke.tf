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
