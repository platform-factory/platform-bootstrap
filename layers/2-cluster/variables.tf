variable "project_id" {
  description = "Same project id set in 0-foundation's terraform.tfvars. The only reason this layer takes it as a raw input at all: Terraform's GCS backend can't be parameterized by another layer's output, so this is needed to locate 1-network's state bucket before anything else (project id, region, network name, ...) can be read from it. Everything downstream reads from .outputs, not from this variable."
  type        = string
  default     = "platform-factory-ref"
}

variable "cluster_name" {
  description = "Name of the GKE cluster. Cluster identity belongs to this layer, not to 1-network or foundation — the VPC can outlive many clusters built on top of it."
  type        = string
  default     = "platform-factory-ref"
}

variable "node_locations" {
  description = "Optional list of zones (within the region) to run cluster nodes in. Null/unset (the default) means GKE auto-selects zones for this regional cluster — normally 3. Override to pin specific zones or narrow the zone count. Per ADR-0009 (mock a real corp environment over cost): a regional control plane spanning multiple zones is what a normal corp runs, superseding this repo's earlier zonal/free-tier design — the ~$0.10/hr regional management fee is accepted, kept small in practice by the teardown rhythm (see README)."
  type        = list(string)
  default     = null
}

variable "machine_type" {
  description = "Machine type for cluster nodes."
  type        = string
  default     = "e2-standard-4"
}

variable "use_spot_nodes" {
  description = "Whether node pool VMs are Spot instead of on-demand. Off by default — per ADR-0009, this build behaves corp-real rather than optimizing for minimum cost, and Spot changes reclaim behavior (nodes can be preempted with little notice), which a normal corp environment wouldn't accept for a baseline node pool. Spot is a cost lever you can still reach for deliberately by flipping this, understanding that trade."
  type        = bool
  default     = false
}

variable "node_count_min" {
  description = "Minimum node count for the autoscaler, PER ZONE — this is a regional cluster, so cluster-wide total is this number times however many zones it spans (3 by default). 1 here means 3 nodes minimum cluster-wide, not 1."
  type        = number
  default     = 1
}

variable "node_count_max" {
  description = "Maximum node count for the autoscaler, PER ZONE (not cluster-total). 2 here means up to 6 nodes cluster-wide across the default 3 zones."
  type        = number
  default     = 2
}

variable "node_count_initial" {
  description = "Node count at cluster creation, PER ZONE (not cluster-total) — initial_node_count has the same regional-cluster semantics as the autoscaler bounds above. 1 here means 3 nodes cluster-wide at creation, before the autoscaler makes its own decisions."
  type        = number
  default     = 1
}

variable "master_ipv4_cidr_block" {
  description = "IP range (must be a /28) for the private control plane's internal endpoint and peering. Must not overlap any other range in the VPC (subnet, pods, services in 1-network) — 172.16.0.0/28 is well outside the 10.x ranges those use."
  type        = string
  default     = "172.16.0.0/28"
}

variable "authorized_networks" {
  description = "CIDR blocks allowed to reach the cluster's public control-plane endpoint — the corp pattern of restricting who can even attempt to authenticate, not just what they can do once in. No default on purpose: you must supply at least your own IP (see terraform.tfvars.example — run `curl -s ifconfig.me` and add it as a /32) before applying. Once the site-to-site VPN in 1-network is live, access can move to the private endpoint over the tunnel instead of the public one."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
}
