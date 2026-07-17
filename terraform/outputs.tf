output "instance_name" {
  value = google_compute_instance.runner.name
}

output "zone" {
  value = google_compute_instance.runner.zone
}

output "external_ip" {
  value = google_compute_instance.runner.network_interface[0].access_config[0].nat_ip
}

output "ssh" {
  description = "SSH in over IAP (no public-IP dependency)."
  value       = "gcloud compute ssh ${google_compute_instance.runner.name} --project=${var.project} --zone=${var.zone} --tunnel-through-iap"
}

output "readiness_check" {
  description = "Run this after ~2-3 min to confirm the startup script finished."
  value       = "gcloud compute ssh ${google_compute_instance.runner.name} --project=${var.project} --zone=${var.zone} --tunnel-through-iap --command='cat /var/log/sluice-provision-done'"
}

output "sluice_vm_env" {
  description = "eval \"$(terraform output -raw sluice_vm_env)\" to point sluice-vm.sh at this runner."
  value       = "export SLUICE_VM_PROJECT=${var.project} SLUICE_VM_ZONE=${var.zone} SLUICE_VM_INSTANCE=${google_compute_instance.runner.name}"
}
