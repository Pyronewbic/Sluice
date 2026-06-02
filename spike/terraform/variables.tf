variable "project" {
  description = "GCP project ID for the spike VM (billing must be enabled)."
  type        = string
  default     = "casecomp-495718"
}

variable "zone" {
  description = "GCP zone. N1 has wide capacity; us-central1-a worked in the spike."
  type        = string
  default     = "us-central1-a"
}

variable "instance_name" {
  type    = string
  default = "sluice-microvm-spike"
}

variable "machine_type" {
  description = "Nested-virt-capable Intel family (N1/N2/C2/C3 - not E2/AMD). N1 chosen for capacity."
  type        = string
  default     = "n1-standard-4"
}

variable "disk_size_gb" {
  type    = number
  default = 40
}
