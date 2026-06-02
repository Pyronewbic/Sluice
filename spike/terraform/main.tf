# Micro-VM isolation spike: a GCP nested-virt VM that boots ready to run sluice under Kata
# Containers (own-kernel micro-VM). Reproduces the manual spike setup. See README.md.

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

# Allow SSH over IAP (so the VM needs no public-IP exposure for `gcloud compute ssh --tunnel-through-iap`).
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

resource "google_compute_instance" "spike" {
  name         = var.instance_name
  machine_type = var.machine_type # n1: abundant capacity + nested-virt-capable (N2 was exhausted in the spike)
  tags         = [var.instance_name]

  # Nested virtualization is REQUIRED: Kata runs a real VM (QEMU/KVM) inside this VM. On N1 it needs a
  # Haswell+ CPU floor. (Not available on E2; Edera's PV model wouldn't need this, but Kata does.)
  min_cpu_platform = "Intel Haswell"
  advanced_machine_features {
    enable_nested_virtualization = true
  }

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = "default"
    access_config {} # ephemeral public IP (egress for the test; SSH still goes over IAP)
  }

  # Installs docker + Kata static + nerdctl + CNI and wires Kata as a containerd runtime.
  metadata_startup_script = file("${path.module}/startup.sh")

  # The spike is throwaway; don't block `terraform destroy`.
  deletion_protection = false
}
