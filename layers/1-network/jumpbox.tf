# The jump box: this VPC's operator reachability, and why it lives in the
# persist layer rather than in the cluster (ADR-0011).
#
# It carries the Tailscale subnet router that advertises local.private_ranges
# into the tailnet, which is how a remote operator reaches workload IPs —
# `psql -h 10.x.x.x` rather than a tunnel-to-a-tunnel. The obvious alternative
# was the Tailscale Kubernetes operator's Connector resource, running in the
# cluster and managed by Argo CD. That was rejected: it would put reachability
# in the disposable layer, so every cycle.sh teardown would destroy user
# access to this VPC. "Identity and reachability persist; compute is
# disposable" is the boundary rule the four-layer split exists to enforce, and
# a subnet router is reachability.
#
# Two independent ways in, with deliberately different failure modes:
#
#   Tailscale — the everyday path. Needs OUTBOUND internet (nat.tf) to reach
#   the coordination server; no inbound, no public IP, no firewall opening.
#
#   IAP TCP forwarding — the break-glass path. Needs INBOUND from Google's
#   IAP range only, and no egress whatsoever. So it still works when NAT is
#   down, when the tailnet is broken, or when the Tailscale auth key has
#   expired — exactly the situations where you need to get in and fix things.
#
# What this deliberately is NOT: a path to the Kubernetes control plane. That
# has no IP at all (2-cluster sets ip_endpoints_config.enabled = false) and is
# reached by its DNS endpoint under IAM. Nothing here is on the kubectl path.

# Its own identity rather than the default Compute Engine service account,
# same reasoning as the GKE node SA in 0-foundation. Defined in this layer
# rather than in foundation because — unlike the node SA, which 2-cluster
# consumes across a layer boundary — this one is consumed only by the VM
# beside it, and pushing it to foundation would add a passthrough for no one.
resource "google_service_account" "jumpbox" {
  project      = var.project_id
  account_id   = "jumpbox"
  display_name = "Jump box identity (1-network) — Tailscale subnet router and break-glass host"
}

# Write-only logging access, nothing more. The VM has no business reading
# project state; anything it eventually needs (for example roles/cloudsql.client
# once there is a database to proxy to) gets added here explicitly.
resource "google_project_iam_member" "jumpbox_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.jumpbox.email}"
}

# The only ingress this VPC opens to the internet-facing world, and it is not
# really the internet: 35.235.240.0/20 is Google's IAP fleet, and traffic only
# arrives from it after IAP has checked the caller's IAM identity. Reaching
# port 22 therefore requires roles/iap.tunnelResourceAccessor, not a network
# position. Scoped by target tag so it applies to this VM and not to nodes.
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "${var.network_name}-allow-iap-ssh"
  network = google_compute_network.vpc.name

  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["jumpbox"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# No return-path firewall rule is needed. firewall.tf's allow_internal
# already permits all protocols from subnet_cidr (plus the pod and Service
# ranges) to everything in this VPC, and the jump box sits inside
# subnet_cidr — so traffic it forwards on behalf of tailnet peers, which
# carries its own address because the subnet router SNATs by default, is
# already covered. A second rule here would be duplication, not defence.

resource "google_compute_instance" "jumpbox" {
  project = var.project_id
  name    = "${var.network_name}-jumpbox"
  zone    = var.jumpbox_zone

  # e2-micro in us-central1 is inside Google's always-free tier (one
  # non-preemptible e2-micro per month across us-west1/us-central1/us-east1,
  # 30 GB standard persistent disk), verified 2026-08-20. A subnet router is
  # not a demanding workload, so the free shape is also the right shape.
  machine_type = var.jumpbox_machine_type

  # Required for a subnet router: without it the VPC network drops packets
  # this VM forwards on behalf of tailnet peers, which presents as the routes
  # being advertised and accepted but nothing being reachable through them.
  can_ip_forward = true

  tags = ["jumpbox"]

  boot_disk {
    initialize_params {
      # Debian rather than Container-Optimized OS on purpose. COS is the more
      # locked-down choice, but this host exists to be used interactively —
      # tailscale, psql, the Cloud SQL Auth Proxy — and COS has no package
      # manager to install any of that. The security tradeoff is accepted and
      # bounded: the machine has no public IP and no inbound path except IAP.
      image = "debian-cloud/debian-12"
      size  = 30
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.subnet.id
    # No access_config block, which is what makes this VM have no external IP.
    # Outbound goes through Cloud NAT (nat.tf); inbound only through IAP.
  }

  service_account {
    email = google_service_account.jumpbox.email
    # cloud-platform relies on IAM for the actual boundary rather than on
    # legacy scopes, which is Google's current guidance. The SA above holds
    # one write-only role, so the effective permission set stays small.
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    # OS Login ties SSH access to IAM identity instead of to metadata SSH
    # keys, which is the same "identity, not position" posture the DNS
    # control-plane endpoint takes. Combined with the IAP-only firewall rule,
    # both the network path and the login are IAM decisions.
    enable-oslogin = "TRUE"

    startup-script = <<-EOT
      #!/usr/bin/env bash
      set -euo pipefail

      # Kernel forwarding, required before Tailscale will act as a subnet
      # router. Written to a file rather than set live so it survives reboot.
      cat > /etc/sysctl.d/99-tailscale.conf <<'SYSCTL'
      net.ipv4.ip_forward = 1
      net.ipv6.conf.all.forwarding = 1
      SYSCTL
      sysctl -p /etc/sysctl.d/99-tailscale.conf

      # Retried, and not under `set -e`, because this is the one step that
      # needs the internet. Cloud NAT is a dependency of this script rather
      # than of the VM boot, and on a first apply the gateway can still be
      # programming when the box comes up — on 2026-08-20 the install won that
      # race by a few seconds, which is not a guarantee. Failing here would
      # leave a jump box with no Tailscale and no signal that anything was
      # wrong until someone went looking.
      if ! command -v tailscale >/dev/null 2>&1; then
        for attempt in 1 2 3 4 5; do
          if curl -fsSL --max-time 60 https://tailscale.com/install.sh | sh; then
            break
          fi
          echo "tailscale install attempt $attempt failed; egress may not be ready" >&2
          sleep 15
        done
      fi

      # Deliberately NOT run here: `tailscale up`. Joining the tailnet needs
      # an auth key, and putting one in instance metadata would write a
      # credential into Terraform state and into the metadata server. The
      # one-time join is an operator step over IAP instead — see the README.
      # Once joined, the node stays joined across reboots.
    EOT
  }

  # The disk is disposable and the machine holds no state worth protecting:
  # everything it does is reinstallable from this startup script plus one
  # `tailscale up`. Left deletable so the layer stays destroyable if the
  # project is ever torn down for real.
  deletion_protection = false

  # Egress has to exist before this box boots, or the startup script's one
  # network-dependent step runs against a VPC with no route out. Terraform
  # sees no relationship between an instance and a NAT gateway on its own, so
  # the ordering has to be stated.
  depends_on = [google_compute_router_nat.this]
}
