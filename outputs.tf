output "instance_private_ip" {
  description = "Private IP address of the GCE instance."
  value       = google_compute_instance.app_server.network_interface[0].network_ip
}

output "instance_network_tags" {
  description = "Network tags applied to the GCE instance (used by firewall rules)."
  value       = google_compute_instance.app_server.tags
}

output "instance_subnet" {
  description = "Subnetwork where the GCE instance is deployed."
  value       = google_compute_instance.app_server.network_interface[0].subnetwork
}
output "instance_id" {
  description = "ID of GCE instace deployed"
  value       = google_compute_instance.app_server.instance_id
}
