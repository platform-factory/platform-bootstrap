# Private Services Access (PSA) — the network half of ADR-0013's
# private-IP-only Cloud SQL.
#
# MENTAL MODEL, because "private IP" is misleading: a Cloud SQL instance
# does NOT live in this VPC. Google builds a separate producer project and
# VPC for the service and joins it to ours with VPC Network Peering. Two
# things are needed to make that join possible, and neither of them is a
# subnet you can see or choose:
#
#   1. An ALLOCATED RANGE — a block of our own RFC1918 space reserved so the
#      producer side can never collide with anything we address ourselves.
#      It is a GLOBAL address (no region), because one allocation covers
#      every region.
#   2. The PRIVATE CONNECTION — the peering itself, established by the
#      Service Networking API against that reserved range.
#
# Google then carves a /29-to-/24 subnet PER REGION out of the allocated
# range, on demand, when the first instance lands in that region, and puts
# the instance there. Those subnets are invisible and unmanageable from our
# side. Verified 2026-09-16 against docs.cloud.google.com/vpc/docs/
# private-services-access: "The service producer typically chooses a /29 to
# /24 CIDR block... If a subnet is full, a new subnet is created in that
# region from the allocated range."
#
# WHY THIS LIVES IN 1-NETWORK, NOT 2-CLUSTER OR A COMPOSITION (ADR-0011's
# boundary rule: identity and reachability persist, compute is disposable).
# The allocated range and the peering are properties of the VPC, and the
# databases that sit on them are ADR-0015 durable resources that outlive
# every cluster rebuild. Putting PSA in 2-cluster would mean `cycle.sh down`
# tears down the network path to databases that still exist — and worse,
# tears it down into Google's four-day producer-resource retention window
# (see the deletion-policy note on the connection below), so the next `up`
# could not rebuild it. Same
# reasoning that moved Cloud NAT here in ADR-0011, applied to a second
# consumer that is even longer-lived than the jump box.
#
# PREREQUISITE IN A LAYER BELOW: servicenetworking.googleapis.com and
# sqladmin.googleapis.com are enabled in 0-foundation's local.services.
# Without the first, this file's connection resource fails; without the
# second, Crossplane's DatabaseInstance fails later with
# SERVICE_NETWORKING_NOT_ENABLED or NETWORK_NOT_PEERED. Layers apply in
# order, so foundation's APIs are on before this runs.
#
# PREREQUISITE FOR A LAYER ABOVE: nothing in Terraform creates a Cloud SQL
# instance here — Crossplane's Database Composition does, in the cluster.
# There is no data dependency to enforce the ordering, so it is stated
# instead: this layer must be applied before the first Database XR
# reconciles. If it has not been, the managed resource sits in a
# NETWORK_NOT_PEERED retry loop rather than failing loudly, which is the
# expensive way to discover a missing peering.

resource "google_compute_global_address" "psa" {
  # Google's own convention for this allocation, and adopting it is not
  # cosmetic: the docs say Google services reuse an existing allocation
  # named this way rather than creating a second one, and the name signals
  # to anyone else in the project that an allocation for Google services
  # already exists. Verified 2026-09-16 against
  # docs.cloud.google.com/vpc/docs/configure-private-services-access.
  name = "google-managed-services-${var.network_name}"

  # VPC_PEERING is what marks this block as "reserved for a service
  # producer to peer into", as opposed to an internal address we hand to a
  # VM or a load balancer.
  purpose      = "VPC_PEERING"
  address_type = "INTERNAL"

  # Pinned rather than auto-allocated. Omitting `address` lets GCP pick any
  # free RFC1918 block, which is non-deterministic across rebuilds and makes
  # the range impossible to write into a route list (locals.tf) or a
  # firewall rule ahead of time. See variables.tf for why /16 and why here.
  address       = var.psa_range_address
  prefix_length = var.psa_range_prefix_length

  network = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "psa" {
  network = google_compute_network.vpc.id
  service = "servicenetworking.googleapis.com"

  # Takes the allocation's NAME, not its CIDR and not its id. Referenced
  # through the resource so Terraform orders the two correctly.
  reserved_peering_ranges = [google_compute_global_address.psa.name]

  # NO deletion_policy HERE, DELIBERATELY — the provider default "DELETE" is
  # what we want, and the tempting alternative is actively worse. Recorded
  # because "set ABANDON so destroy never fails" is the obvious-looking move
  # and it does not do what it appears to.
  #
  # What DELETE does (verified 2026-09-16 by reading the provider source at
  # the version this layer's lock file pins, hashicorp/google v7.42.0,
  # google/services/servicenetworking/resource_service_networking_connection.go):
  # the schema entry is DeletionPolicySchemaEntry("DELETE"), and Delete()
  # calls DeletionPolicyPreDelete first — which returns early ONLY for
  # ABANDON — then issues a real Services.Connections.DeleteConnection
  # against ".../connections/servicenetworking-googleapis-com". So DELETE is
  # the only policy that actually removes the peering this connection put on
  # our VPC.
  #
  # The failure mode DELETE owns, and it is bounded. Google's doc says that
  # after a Cloud SQL instance is deleted "the service waits for FOUR DAYS
  # before deleting the service producer resources... If you try to delete
  # the connection during the waiting period, the deletion fails with a
  # message that the resources are still in use by the service producer."
  # So a `terraform destroy` of this layer within four days of any database
  # being deleted fails AT THIS RESOURCE. Everything already destroyed stays
  # destroyed, this connection stays in state, and re-running the destroy
  # once the window closes finishes the job. Outside that window — which is
  # every destroy where no database was recently deleted, including every
  # destroy of a project that never had one — it simply succeeds.
  #
  # Why ABANDON would be worse, not better. ABANDON drops the connection
  # from state WITHOUT calling DeleteConnection, so the VPC Network Peering
  # it created stays attached to our VPC. Terraform then proceeds to
  # google_compute_network.vpc and fails there instead, because
  # docs.cloud.google.com/vpc/docs/create-modify-vpc-networks (read
  # 2026-09-16) is explicit: "Before you can delete a network, you must
  # delete all resources in all of its subnets, and all resources that
  # reference the network. Resources that reference the network include VPC
  # Network Peering connections..." That failure happens on EVERY destroy,
  # not just inside the four-day window, and because the connection is no
  # longer in state Terraform cannot retry its way out of it — the operator
  # has to run `gcloud services vpc-peerings delete
  # --service=servicenetworking.googleapis.com --network=<vpc>` by hand,
  # which is the same call DELETE would have made and is subject to the same
  # four-day wait. (Do not "fix" that by deleting the VPC peering object
  # directly; the PSA doc warns against it explicitly.) Trading a rare,
  # retryable, self-contained failure for a universal one that needs manual
  # cleanup is not a trade worth making.
  #
  # Frequency, honestly: near zero either way. scripts/cycle.sh's
  # DISPOSABLE_LAYERS is 2-cluster and 3-argocd only and it refuses to touch
  # this layer, so nothing in the normal rhythm destroys 1-network. This
  # only comes up on a full project rebuild.

  # The self-heal for an orphaned connection. If one already exists on this
  # VPC with different ranges — created by the console wizard, left behind
  # by an apply whose state was lost, or by the manual gcloud cleanup path
  # above being skipped — the create call returns "Cannot modify allocated
  # ranges in CreateConnection." With this flag the provider retries as a
  # forced Patch of the existing connection instead of failing; without it
  # the operator's only way forward is a manual `terraform import` of
  # "projects/<project>/global/networks/<vpc>:servicenetworking.googleapis.com".
  # Verified 2026-09-16 by reading the provider's Create() path at v7.42.0.
  update_on_creation_fail = true
}
