# Same formula 0-foundation used to name the bucket in the first place
# (see its main.tf), recomputed here because this is a separate state file
# with no way to import that layer's locals directly — only its outputs,
# and we need the bucket name before we can read those.
locals {
  tfstate_bucket = "${var.project_id}-tfstate"
}

# The Private Services Access allocation, reassembled into a CIDR string.
# google_compute_global_address takes the address and the prefix length as
# two separate fields (psa.tf); route lists want one string.
locals {
  psa_range_cidr = "${var.psa_range_address}/${var.psa_range_prefix_length}"
}

# The private ranges a remote operator needs routes to in order to reach
# anything in this VPC: the subnet's primary range, both secondary ranges,
# and (since M2) the Private Services Access range that Cloud SQL private
# IPs come out of.
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
# Deliberately transport-neutral. These are the same ranges the HA VPN
# advertises over BGP when enable_vpn = true, and the same ranges a Tailscale
# subnet router advertises into the tailnet. Changing how operators connect
# does not change what they need to reach, so this list is defined once here
# rather than inside vpn.tf. (The PSA entry is the one range where the
# transport does matter — see the note below the list.)
locals {
  private_ranges = [var.subnet_cidr, var.pods_cidr, var.services_cidr, local.psa_range_cidr]
}

# WHY THE PSA RANGE IS IN THAT LIST (added 2026-09-16, M2).
#
# ADR-0013 §5 says humans reach their database the same way the application
# does — `psql` from the tailnet with an IAM login token, no shared
# password. The instance has a private IP only, and that IP comes out of
# the PSA allocation (psa.tf), NOT out of subnet_cidr — so without this
# entry a laptop on the tailnet has no route to it at all and the whole
# "developers use the same door" half of ADR-0013 does not work.
#
# What makes the path work end to end, and it is not obvious: the Cloud SQL
# instance lives in Google's producer VPC, peered to ours, and that producer
# network learns only our SUBNET ROUTES by default — "any request that's not
# from a subnet IP range is dropped by the service producer"
# (docs.cloud.google.com/vpc/docs/private-services-access, read 2026-09-16).
# Traffic from a tailnet peer survives that rule because the Tailscale
# subnet router SNATs to its own address, which is inside subnet_cidr. So
# the packet the producer sees comes from a subnet IP and its reply is
# routable. [I — the SNAT-by-default behaviour is the documented Tailscale
# default and the same assumption jumpbox.tf's "no return-path firewall
# rule is needed" comment already rests on, but the psql-over-tailnet path
# has not been exercised yet. Verify on the first database; if it does not
# SNAT, this range also needs exporting to the producer with
# google_compute_network_peering_routes_config.]
#
# GKE pods need nothing here: pod IPs are alias IPs from the subnet's
# secondary range, which IS a subnet route, so svc-hello's Cloud SQL Auth
# Proxy sidecar reaches the instance with no extra configuration. Google's
# own sample adds a peering-routes-config resource for this; do not copy it
# in — it solves a problem this topology does not have.
#
# OVER THE HA VPN (enable_vpn = true) THIS RANGE IS ADVERTISED BUT NOT
# SUFFICIENT. vpn.tf advertises every entry in this list over BGP, which
# correctly steers a peer-network packet for 10.60.x.x toward GCP — but
# there is no SNAT on that path, so the packet arrives at the producer
# carrying the peer's own source address, which the producer has not
# learned, and the reply is dropped. Making that work additionally needs
# custom-route export on the peering. Named here rather than built: the VPN
# is unbuilt (ADR-0011) and reaching a database from the peer site is not a
# requirement anything has asked for.
#
# MANUAL STEP THIS CREATES. private_ranges is what
# output.jumpbox_tailscale_up_command advertises, so adding a fourth range
# changes that command. An already-joined jump box does NOT pick it up: an
# operator must re-run `tailscale up` with the new route set on the box (over
# IAP), and the new route must then be approved in the Tailscale admin
# console before peers can use it. Same one-time-operator-step cost ADR-0011
# already accepted for the auth key, incurred once more.
