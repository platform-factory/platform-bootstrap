variable "project_id" {
  description = "Same project id set in 0-foundation's terraform.tfvars. The only reason this layer takes it as a raw input at all: Terraform's GCS backend can't be parameterized by another layer's output, so this is needed to locate foundation's state bucket before anything else (project id, region, ...) can be read from it. Everything downstream reads from .outputs, not from this variable."
  type        = string
  default     = "platform-factory-ref"
}

variable "zone" {
  description = "Zone for the GKE cluster and its node pool. A zonal (single-zone) cluster instead of regional: GKE only charges the cluster management fee on regional/multi-zone clusters, so one zonal cluster stays in the free tier."
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "Name of the GKE cluster. Cluster identity belongs to this layer, not to foundation."
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
