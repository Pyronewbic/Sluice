# The sluice Linux test-runner VM. Default: a cheap e2 Docker host that runs `make test` on real
# Linux (see terraform/README.md + sluice-vm.sh). enable_kata=true adds the nested-virt Kata micro-VM
# stack to exercise SLUICE_RUNTIME=kata (was the spike/ that proved that path).

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

provider "google" {
  project = var.project
  zone    = var.zone
}

locals {
  # e2 (cheap) for the Docker runner; a nested-virt-capable type only when Kata is requested.
  machine_type = var.enable_kata ? var.kata_machine_type : var.machine_type
}

# SSH over IAP, so the VM needs no public-IP exposure for `gcloud compute ssh --tunnel-through-iap`.
resource "google_compute_firewall" "iap_ssh" {
  name    = "${var.instance_name}-iap-ssh"
  network = "default"
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"] # Google IAP TCP-forwarding range
  target_tags   = [var.instance_name]
}

resource "google_compute_instance" "runner" {
  name         = var.instance_name
  machine_type = local.machine_type
  tags         = [var.instance_name]
  labels       = { purpose = "sluice-ci" }

  # Kata runs a real VM (QEMU/KVM) inside this VM, so it needs nested virt + a Haswell+ floor (N1/N2/
  # C2/C3, never E2). The plain Docker runner needs none of that, so both are gated on enable_kata.
  dynamic "advanced_machine_features" {
    for_each = var.enable_kata ? [1] : []
    content {
      enable_nested_virtualization = true
    }
  }
  min_cpu_platform = var.enable_kata ? "Intel Haswell" : null

  boot_disk {
    initialize_params {
      image = var.image
      size  = var.disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = "default"
    access_config {} # ephemeral public IP for egress (apt/docker/GitHub); SSH still goes over IAP
  }

  # startup.sh reads these to decide whether to install the Kata stack and/or the VHS render stack.
  metadata = {
    enable-kata = var.enable_kata ? "1" : "0"
    enable-vhs  = var.enable_vhs ? "1" : "0"
  }
  metadata_startup_script = file("${path.module}/startup.sh")

  deletion_protection = false # a disposable runner - never block `terraform destroy`
}
