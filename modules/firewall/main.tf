resource "google_compute_firewall" "fw"{
    name = var.name
    network = var.network    
    source_ranges = var.source_ranges
    target_tags =  var.target_tags
    
    allow {
        protocol = var.protocol
        ports = var.ports
        }
}