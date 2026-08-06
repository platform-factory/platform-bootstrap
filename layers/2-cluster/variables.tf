variable "project_id" {
  description = "Same project id set in 0-foundation's terraform.tfvars. The only reason this layer takes it as a raw input at all: Terraform's GCS backend can't be parameterized by another layer's output, so this is needed to locate 1-network's state bucket before anything else (project id, region, network name, ...) can be read from it. Everything downstream reads from .outputs, not from this variable."
  type        = string
  default     = "platform-factory-ref"
}

variable "zone" {
  description = "Zone for the GKE cluster and its node pool. A zonal (single-zone) cluster instead of regional: GKE only charges the cluster management fee on regional/multi-zone clusters, so one zonal cluster stays in the free tier."
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "Name of the GKE cluster. Cluster identity belongs to this layer, not to 1-network or foundation — the VPC can outlive many clusters built on top of it."
  type        = string
  default     = "platform-factory-ref"
}

variable "machine_type" {
  description = "Machine type for cluster nodes."
  type        = string
  default     = "e2-standard-4"
}

variable "node_count_min" {
  description = "Minimum node count for the autoscaler."
  type        = number
  default     = 1
}

variable "node_count_max" {
  description = "Maximum node count for the autoscaler."
  type        = number
  default     = 3
}

variable "node_count_initial" {
  description = "Node count at cluster creation, before the autoscaler makes its own decisions."
  type        = number
  default     = 2
}
