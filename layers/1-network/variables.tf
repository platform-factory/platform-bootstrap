variable "project_id" {
  description = "Same project id set in 0-foundation's terraform.tfvars. The only reason this layer takes it as a raw input at all: Terraform's GCS backend can't be parameterized by another layer's output, so this is needed to locate foundation's state bucket before anything else (project id, region, ...) can be read from it. Everything downstream reads from .outputs, not from this variable."
  type        = string
  default     = "platform-factory-ref"
}

variable "network_name" {
  description = "Name for the VPC (the subnet is named \"<network_name>-subnet\"). Network identity belongs to this layer, not to foundation or to the cluster that happens to run on it."
  type        = string
  default     = "platform-factory-ref"
}

variable "subnet_cidr" {
  description = "Primary IP range for the subnet (node IPs)."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary IP range for pod IPs (VPC-native / alias IP cluster)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary IP range for Kubernetes Service IPs (VPC-native / alias IP cluster)."
  type        = string
  default     = "10.30.0.0/20"
}

# --- VPN (vpn.tf) -----------------------------------------------------------
# Off by default. This VPC is meant to persist across sessions specifically
# so its VPN connection to another network doesn't have to be rebuilt every
# time — but that only matters once there's a peer to connect to. See the
# README's VPN section before flipping this on.

variable "enable_vpn" {
  description = "Turns on the HA VPN gateway, tunnels, and BGP peering in vpn.tf. False by default: with it false, this layer is just a VPC and subnet. Flip to true once the peer (home/corp) gateway is configured and its public IP and BGP ASN are known."
  type        = bool
  default     = false
}

variable "peer_gateway_ip" {
  description = "Public IP of the peer VPN gateway (the WAN address of the home/corp gateway this connects to — a UniFi gateway, for this build). Required when enable_vpn = true; left null otherwise."
  type        = string
  default     = null
  nullable    = true

  validation {
    # Cross-variable reference — requires Terraform >= 1.9, already the
    # floor in versions.tf.
    condition     = !var.enable_vpn || var.peer_gateway_ip != null
    error_message = "peer_gateway_ip is required when enable_vpn = true."
  }
}

variable "cloud_router_asn" {
  description = "ASN for the Google-side Cloud Router. 64514 is arbitrary but sits in the private-use ASN range (64512-65534), matching Google's own Cloud Router examples."
  type        = number
  default     = 64514
}

variable "peer_asn" {
  description = "ASN the peer (UniFi) side advertises over BGP. Must differ from cloud_router_asn."
  type        = number
  default     = 64515
}

variable "vpn_shared_secret" {
  description = "Pre-shared key (PSK) for both VPN tunnels, matching whatever is configured on the peer side. No default — set it in the gitignored terraform.tfvars. Nullable so `terraform validate` passes with it unset while enable_vpn is false; the provider will require a real value at plan/apply time once enable_vpn = true actually creates the tunnels."
  type        = string
  sensitive   = true
  default     = null
  nullable    = true
}

# --- jump box (jumpbox.tf) --------------------------------------------------
# Always created, unlike the VPN. Per ADR-0011 this is the VPC's operator
# reachability rather than an optional extra, and it is the persist-layer home
# for the Tailscale subnet router.

variable "jumpbox_zone" {
  description = "Zone for the jump box. Single-zone on purpose: this is a break-glass and routing host, not a highly available service, and a zonal outage is survivable by recreating it (the startup script plus one `tailscale up` is the whole build)."
  type        = string
  default     = "us-central1-a"
}

variable "jumpbox_machine_type" {
  description = "Machine size for the jump box. e2-micro is inside Google's always-free tier in us-central1 and is ample for a subnet router; raise it only if the box starts doing real work."
  type        = string
  default     = "e2-micro"
}

# --- Private Services Access (psa.tf) ---------------------------------------
# The reserved block Google's Cloud SQL producer network peers into. Split
# into an address and a prefix length rather than one CIDR string because
# that is the shape google_compute_global_address takes; locals.tf
# reassembles them into a CIDR for the route list.

variable "psa_range_address" {
  description = "Start address of the Private Services Access allocated range. Pinned rather than auto-allocated so the block is deterministic across rebuilds and can be written into route lists ahead of time. 10.60.0.0 is clear of every other range in this VPC's plan (subnet 10.10.0.0/20, pods 10.20.0.0/16, services 10.30.0.0/20) and of 2-cluster's control-plane /28 at 172.16.0.0/28, with a readable gap between them."
  type        = string
  default     = "10.60.0.0"
}

variable "psa_range_prefix_length" {
  description = "Prefix length of the Private Services Access allocated range. 16 is Google's own recommendation for Google services (\"the minimum size is a single /24 block, but the recommended size is a /16 block\", docs.cloud.google.com/vpc/docs/configure-private-services-access, read 2026-09-16), and a /16 costs nothing: the documented quota is on the NUMBER of allocated ranges, explicitly not on the size of each. A /20 would be ample for one region, but the failure mode is asymmetric — growing the range later means either expanding in place (only possible if the adjacent space happens to be free) or a second allocation plus a forced peering update, and once a Cloud SQL instance exists both are blocked by Google's four-day producer-resource retention (see psa.tf). The one real counter-argument: if enable_vpn is ever flipped on, a /16 out of 10.x is more address space to coordinate with the peer network."
  type        = number
  default     = 16
}
