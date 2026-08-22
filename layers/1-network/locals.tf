# Same formula 0-foundation used to name the bucket in the first place
# (see its main.tf), recomputed here because this is a separate state file
# with no way to import that layer's locals directly — only its outputs,
# and we need the bucket name before we can read those.
locals {
  tfstate_bucket = "${var.project_id}-tfstate"
}

# The private ranges a remote operator needs routes to in order to reach
# anything in this VPC: the subnet's primary range plus both secondary ranges.
#
# What that actually buys, measured over the tailnet on 2026-08-22 rather than
# assumed: node IPs reachable, pod IPs reachable, Service ClusterIPs NOT.
# ClusterIPs are virtual — kube-proxy rules on each node translate them, and
# they are never real addresses on the VPC network — so no amount of routing
# reaches them from outside. services_cidr stays in this list because it is
# genuinely part of the VPC's IP plan and reserving it keeps the ranges from
# colliding, not because advertising it makes Services reachable. To reach a
# Service from the tailnet, use an internal load balancer or the Tailscale
# Kubernetes operator's Ingress, which exposes Services by name.
#
# The superseded version of this comment claimed "pod and Service IPs are
# reachable from the peer network too." That was wrong, and had been wrong
# since it was written for the VPN — it survived only because the VPN was
# never built and nothing exercised it. See surprise 16 in the build log.
#
# Deliberately transport-neutral. These are the same three ranges the HA VPN
# advertises over BGP when enable_vpn = true, and the same three a Tailscale
# subnet router advertises into the tailnet. Changing how operators connect
# does not change what they need to reach, so this list is defined once here
# rather than inside vpn.tf.
locals {
  private_ranges = [var.subnet_cidr, var.pods_cidr, var.services_cidr]
}
