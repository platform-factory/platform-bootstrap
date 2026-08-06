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
  # the internet via Cloud NAT (nat.tf, in this layer, not 1-network — see
  # its comment for why). enable_private_endpoint = false: the control
  # plane keeps a public endpoint too, gated by master_authorized_networks_config
  # below, rather than going fully private — see that block's comment for
  # why.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  # Corp pattern: restrict who can even attempt to authenticate to the
  # public endpoint, not just what they can do once authenticated. No
  # default for var.authorized_networks — this only applies once an
  # operator has actually supplied their own IP. Once the site-to-site VPN
  # in 1-network is live, this could move to the private endpoint over the
  # tunnel instead of keeping a public one open at all.
  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
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
