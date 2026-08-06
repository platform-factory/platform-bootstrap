resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone # zonal, not regional — see var.zone description

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

  # Evolution note: nodes are on public IPs for now (no Cloud NAT, no
  # private-nodes config). That changes with the egress-control work (M3),
  # and Cloud NAT will live in THIS layer, not 1-network — it serves nodes,
  # so it should be created and destroyed on the same schedule they are.
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = data.terraform_remote_state.network.outputs.pods_range_name
    services_secondary_range_name = data.terraform_remote_state.network.outputs.services_range_name
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
  # would block exactly that.
  deletion_protection = false
}

resource "google_container_node_pool" "primary" {
  name     = "primary"
  cluster  = google_container_cluster.primary.name
  location = var.zone

  initial_node_count = var.node_count_initial

  autoscaling {
    min_node_count = var.node_count_min
    max_node_count = var.node_count_max
  }

  node_config {
    machine_type = var.machine_type

    # Spot VMs: acceptable for a reference build that isn't serving
    # production traffic — meaningfully cheaper, at the cost of nodes that
    # can be reclaimed with little notice.
    spot = true

    # Broad node scope is safe here specifically because workload identity
    # (above) is what actually gates pod-level GCP access — pods don't
    # inherit the node's scope, so this isn't the node-level "everything"
    # access it would be without workload identity turned on.
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }
}
