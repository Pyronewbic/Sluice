output "instance_name" {
  value = google_compute_instance.spike.name
}

output "zone" {
  value = google_compute_instance.spike.zone
}

output "external_ip" {
  value = google_compute_instance.spike.network_interface[0].access_config[0].nat_ip
}

output "ssh" {
  description = "SSH in over IAP (no public-IP dependency)."
  value       = "gcloud compute ssh ${google_compute_instance.spike.name} --project=${var.project} --zone=${var.zone} --tunnel-through-iap"
}

output "readiness_check" {
  description = "Run this after ~2-3 min to confirm the startup script finished."
  value       = "gcloud compute ssh ${google_compute_instance.spike.name} --zone=${var.zone} --tunnel-through-iap --command='cat /var/log/spike-ready'"
}
