variable "project" {
  description = "GCP project ID (billing enabled). No default - set it in terraform.tfvars (gitignored) or with -var, so no personal project id lives in the repo."
  type        = string
}

variable "zone" {
  description = "GCP zone."
  type        = string
  default     = "us-central1-a"
}

variable "instance_name" {
  description = "VM (and derived firewall/tag) name."
  type        = string
  default     = "sluice-ci"
}

variable "machine_type" {
  description = "Machine type for the default Docker test-runner. e2 is cheapest; ignored in favor of kata_machine_type when enable_kata=true (e2 cannot do nested virtualization)."
  type        = string
  default     = "e2-standard-2"
}

variable "enable_kata" {
  description = "Also provision the Kata micro-VM stack (containerd/nerdctl + CNI) to exercise SLUICE_RUNTIME=kata. Forces a nested-virt-capable machine and an Intel Haswell CPU floor."
  type        = bool
  default     = false
}

variable "kata_machine_type" {
  description = "Machine type used when enable_kata=true. Must be nested-virt-capable (N1/N2/C2/C3 - not E2 or AMD)."
  type        = string
  default     = "n1-standard-4"
}

variable "disk_size_gb" {
  description = "Boot disk size (GB). Kata's static bundle wants a little more headroom."
  type        = number
  default     = 30
}

variable "image" {
  description = "Boot image (project/family). Debian and Ubuntu both ship mawk as /usr/bin/awk (no --re-interval), which usefully catches awk-portability bugs the macOS/CI awk would pass."
  type        = string
  default     = "debian-cloud/debian-12"
}

variable "enable_vhs" {
  description = "Also install the VHS render stack (vhs + ttyd + ffmpeg + headless chromium + fonts) to record the demo tapes (assets/demos/*.tape) on this VM. Independent of enable_kata; default off so the plain Docker test-runner stays lean."
  type        = bool
  default     = false
}
