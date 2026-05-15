// Output the Load Balancer IP to test access
output "load_balancer_public_ip" {
  value       = google_compute_global_address.lb_ip.address
  description = "The external IP address of the HTTP Load Balancer. Access this via http://<IP> to test."
}